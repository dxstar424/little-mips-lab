`timescale 1ns / 1ps
`include "headder.vh"

module Core(
    input wire clk,
    input wire rst,
    output wire [31:0]pc_o,
    input wire [31:0]inst,
    output wire inst_req,
    output wire data_req,
    output wire data_we,
    output wire data_re,
    output wire dmem_w,
    output wire dmem_r,
    output wire [3:0]be,
    output wire [31:0]dmem_addr,
    output wire [31:0]dmem_wdata,
    input wire [31:0]dmem_rdata,
    input wire mem_stall
    );
    reg [31:0]pc;
    reg [31:0]ifid_pc;
    reg [31:0]ifid_inst;
    reg ifid_v;
    wire fit;
    wire [31:0]fit_target;
    wire if_stall;

    // Branch predictor signals (Lab4)
    wire        bp_taken;
    wire [31:0] bp_target;
    wire        bp_mispredict;
    reg         ifid_pred_taken;    // prediction for instruction in ID stage
    reg [31:0]  ifid_pred_target;
    reg         idex_pred_taken;    // prediction for instruction in EX stage
    reg [31:0]  idex_pred_target;

    // Branch predictor update signals
    wire bp_update_valid;
    wire bp_update_taken;

    wire [4:0] id_rs;
    wire [4:0] id_rt;
    wire [4:0] id_rd;
    wire id_reg_w;
    wire [3:0] id_alu_type;
    wire [1:0] id_A;
    wire [1:0] id_B;
    wire id_dmem_r;
    wire id_dmem_w;
    wire id_dmem_use_be;
    wire [3:0]id_br_type;
    wire id_datatoreg;
    wire id_use_rs;
    wire id_use_rt;
    wire id_is_branch;
    
    wire [31:0]id_imm;
    wire [31:0]id_rs_val;
    wire [31:0]id_rt_val;
    
    wire [31:0]id_rs_val_f;
    wire [31:0]id_rt_val_f;
    wire id_stall;
    
    reg [31:0]idex_pc;
    reg [4:0]idex_rs;
    reg [4:0]idex_rt;
    reg [4:0]idex_rd;
    reg [1:0]idex_A;
    reg [1:0]idex_B;
    reg idex_reg_w;
    reg idex_dmem_r;
    reg idex_dmem_w;
    reg idex_dmem_use_be;
    
    reg idex_datatoreg;
    reg [3:0]idex_alu_type;
    reg [31:0]idex_imm;
    reg [3:0]idex_br_type;
    reg idex_use_rs;
    reg idex_use_rt;
    reg [31:0]idex_rs_val;
    reg [31:0]idex_rt_val;
    reg idex_is_branch;
    reg idex_v;
    
    wire [31:0]ex_alu_out;
    wire ex_is_branch;
    wire [31:0]ex_addr;
    wire [31:0]ex_wdata;
    wire ex_stall;
    
    reg [31:0]exmem_alu_out;
    reg [31:0]exmem_addr;
    reg [31:0]exmem_wdata;
    reg exmem_dmem_r;
    reg exmem_dmem_w;
    reg exmem_reg_w;
    reg [4:0]exmem_rd;
    reg exmem_datatoreg;
    reg exmem_v;
    wire [31:0]dmem_rdata_be;
    reg[4:0]wb_rd;
    reg[31:0]wb_reg_wdata;
    reg wb_reg_w;
    wire wb_stall;
    
    assign pc_o = pc;

    // Prediction-based early target redirect (Lab4)
    reg         pred_delayed_branch;
    reg [31:0]  pred_delayed_target;

    always @(posedge clk)begin
        if(rst)begin
            pc <= 32'h80000000;
            pred_delayed_branch <= 1'b0;
            pred_delayed_target  <= 32'b0;
        end
        // Priority 1: Mispredict flush — redirect to correct path
        else if (bp_mispredict & (~mem_stall))begin
            if(ex_actual_taken)
                pc <= fit_target;            // actually taken (target wrong or unpredicted)
            else
                pc <= idex_pc + 32'd8;      // actually not taken: sequential past delay slot
            pred_delayed_branch <= 1'b0;
        end
        // Priority 2: Branch actually taken but not predicted
        else if (fit & (~mem_stall) & ~idex_pred_taken)begin
            pc <= fit_target;
            pred_delayed_branch <= 1'b0;
        end
        // Priority 3: Normal PC advance
        else if((~if_stall) & (~mem_stall))begin
            if(pred_delayed_branch) begin
                // After delay slot: go to predicted target
                pc <= pred_delayed_target;
                pred_delayed_branch <= 1'b0;
            end
            else begin
                // Look up BHT for instruction at current pc
                // If predicts taken, redirect AFTER the next instruction (delay slot)
                if(bp_taken) begin
                    pred_delayed_branch <= 1'b1;
                    pred_delayed_target  <= bp_target;
                end
                pc <= pc + 32'h4;
            end
        end
    end
    assign if_stall = id_stall;

    // ---- ifid valid + prediction pipeline (Lab4) ----
    always @(posedge clk)begin
        if(rst)begin
            ifid_v          <= 1'b0;
            ifid_pred_taken   <= 1'b0;
            ifid_pred_target  <= 32'b0;
        end
        else if(mem_stall)begin
            ifid_v          <= ifid_v;
            ifid_pred_taken   <= ifid_pred_taken;
            ifid_pred_target  <= ifid_pred_target;
        end
        else if (bp_mispredict | (fit & ~idex_pred_taken))begin
            // Flush IF/ID on mispredict, or on taken branch that was NOT predicted.
            // If the branch WAS predicted taken (idex_pred_taken=1), the target
            // instruction is already in IF — keep it alive.
            ifid_v          <= 0;
            ifid_pred_taken   <= 1'b0;
            ifid_pred_target  <= 32'b0;
        end else begin
            if(~id_stall)begin
                ifid_v          <= ~if_stall;
                // Capture prediction for the instruction just fetched
                ifid_pred_taken   <= bp_taken;
                ifid_pred_target  <= bp_target;
            end
        end
    end
    always @(posedge clk)begin
        if(rst)begin
            ifid_pc <= 32'h0;
            ifid_inst <= 32'h0;
        end
        else if(mem_stall)begin
            ifid_pc <= ifid_pc;
            ifid_inst <= ifid_inst;
        end
        else begin
            if(~id_stall)begin
                ifid_pc <= pc;
                ifid_inst <= inst;
            end
        end
    end
    
    Decode dec(
        .inst(ifid_inst),
        .rs(id_rs),
        .rt(id_rt),
        .rd(id_rd),
        .reg_wen(id_reg_w),
        .imm(id_imm),
        .alu_type(id_alu_type),
        .A(id_A),
        .B(id_B),
        .dmem_ren(id_dmem_r),
        .dmem_wen(id_dmem_w),
        .dmem_use_be(id_dmem_use_be),
        .br_type(id_br_type),
        .datatoreg(id_datatoreg),
        .use_rs(id_use_rs),
        .use_rt(id_use_rt),
        .is_branch_type(id_is_branch)
    );

    branch_predictor #(
        .ENTRIES(`BHT_ENTRIES),
        .INDEX_W(`BHT_INDEX_BITS)
    ) bp (
        .clk(clk),
        .rst(rst),
        .lookup_pc(pc),
        .pred_taken(bp_taken),
        .pred_target(bp_target),
        .update_valid(bp_update_valid),
        .update_pc(idex_pc),
        .update_taken(bp_update_taken),
        .update_target(fit_target)
    );

    regfile ref(
        .clk(clk),
        .rst(rst),
        .rs(id_rs),
        .rt(id_rt),
        .rd(wb_rd),
        .data(wb_reg_wdata),
        .reg_wen(wb_reg_w),
        .rs_val(id_rs_val),
        .rt_val(id_rt_val)
    );
    wire data_stall;
    wire id_data_stall;
    assign id_data_stall = data_stall&ifid_v;
    forward fu(
        .id_rs(id_rs),
        .id_rt(id_rt),
        .id_rs_val(id_rs_val),
        .id_rt_val(id_rt_val),
        .id_use_rs(id_use_rs),
        .id_use_rt(id_use_rt),
        
        .ex_v(idex_v),
        .ex_rd(idex_rd),
        .ex_reg_w(idex_reg_w),
        .ex_alu_out(ex_alu_out),
        .ex_datatoreg(idex_datatoreg),
        .mem_v(exmem_v),
        .mem_rd(exmem_rd),
        .mem_reg_w(exmem_reg_w),
        .mem_alu_out(exmem_alu_out),
        .mem_datatoreg(exmem_datatoreg),
        .dmem_rdata(dmem_rdata_be),
        
        .id_rs_val_f(id_rs_val_f),
        .id_rt_val_f(id_rt_val_f),
        .id_data_stall(data_stall)
    );
    
    assign id_stall = ex_stall | id_data_stall;

    // ---- idex_v with prediction pipeline (Lab4) ----
    always@ (posedge clk)begin
        if(rst)begin
            idex_v          <= 1'b0;
            idex_pred_taken   <= 1'b0;
            idex_pred_target  <= 32'b0;
        end
        else if(mem_stall)begin
            idex_v          <= idex_v;
            idex_pred_taken   <= idex_pred_taken;
            idex_pred_target  <= idex_pred_target;
        end
        else if(bp_mispredict)begin
            // Clear prediction state but keep idex_v alive:
            // the delay slot is in ID and must execute.
            idex_pred_taken   <= 1'b0;
            idex_pred_target  <= 32'b0;
        end
        else if(~ex_stall)begin
            if(id_stall)begin
                idex_v          <= 1'b0;
                idex_pred_taken   <= 1'b0;
                idex_pred_target  <= 32'b0;
            end
            else begin
                idex_v          <= ifid_v;
                idex_pred_taken   <= ifid_pred_taken;
                idex_pred_target  <= ifid_pred_target;
            end
        end
    end
    always @(posedge clk)begin
        if(rst)begin
            idex_pc <= 32'b0;
            idex_rs_val <= 32'b0;
            idex_rt_val <= 32'b0;
            idex_A <= 2'b0;
            idex_B <= 2'b0;
            idex_rs <= 5'b0;
            idex_rt <= 5'b0;
            idex_rd <= 5'b0;
            idex_reg_w <= 1'b0;
            idex_dmem_r <= 1'b0;
            idex_dmem_w <= 1'b0;
            idex_dmem_use_be <= 1'b0;
            idex_datatoreg <= 1'b0;
            idex_imm <= 32'b0;
            idex_br_type <= 4'b0;
            idex_alu_type <= 4'b0;
            idex_is_branch <= 1'b0;
        end
        else if(mem_stall)begin
            idex_pc <= idex_pc;
            idex_rs_val <= idex_rs_val;
            idex_rt_val <= idex_rt_val;
            idex_A <= idex_A;
            idex_B <= idex_B;
            idex_rs <= idex_rs;
            idex_rt <= idex_rt;
            idex_rd <= idex_rd;
            idex_reg_w <= idex_reg_w;
            idex_dmem_r <= idex_dmem_r;
            idex_dmem_w <= idex_dmem_w;
            idex_dmem_use_be <= idex_dmem_use_be;
            idex_datatoreg <= idex_datatoreg;
            idex_imm <= idex_imm;
            idex_br_type <= idex_br_type;
            idex_alu_type <= idex_alu_type;
            idex_is_branch <= idex_is_branch;
        end
        else if(~ex_stall) begin
			idex_pc <= ifid_pc;
			idex_rs_val <= id_rs_val_f;
			idex_rt_val <= id_rt_val_f;
			idex_A <= id_A;
			idex_B <= id_B;
			idex_rs <= id_rs;
			idex_rt <= id_rt;
			idex_rd <= id_rd;
			idex_reg_w <= id_reg_w;
			idex_dmem_r <= id_dmem_r;
			idex_dmem_w <= id_dmem_w;
			idex_dmem_use_be <= id_dmem_use_be;
			idex_datatoreg <= id_datatoreg;
			idex_imm <= id_imm;
			idex_br_type <= id_br_type;
			idex_alu_type <= id_alu_type;
			idex_is_branch <= id_is_branch;
        end
    end
    wire [31:0]alu_a_val,alu_b_val;
    assign alu_a_val = ~|(idex_A ^ `A_RS)? idex_rs_val:~|(idex_A ^ `A_PC)?idex_pc:idex_imm;
    assign alu_b_val = ~|(idex_B ^ `B_SI)? idex_imm:~|(idex_B ^ `B_RT)? idex_rt_val:32'h8;
    wire ex_alu_stall;
    wire jump;
    assign fit = jump&idex_v;
    ALU alu (
        .clk(clk),
        .rst(rst),
        .a(alu_a_val),
        .b(alu_b_val),
        .alu_type(idex_alu_type),
        .valid(idex_v),
        .ex_stall(ex_stall),
        .mem_stall(mem_stall),
        .out_res(ex_alu_out),
        .alu_stall(ex_alu_stall),
        .br_type(idex_br_type),
        .jump(jump),
        .pc(idex_pc),
        .rs_v(idex_rs_val),
        .imm(idex_imm),
        .branch(fit_target)
    );

    // ---- Mispredict detection (Lab4) ----
    wire ex_actual_taken;
    assign ex_actual_taken = jump & idex_v;
    // Mispredict if: direction wrong, OR direction right but target wrong (JR/JALR)
    assign bp_mispredict = idex_is_branch & idex_v &
        ((idex_pred_taken != ex_actual_taken) |
         (idex_pred_taken & ex_actual_taken & (idex_pred_target != fit_target)));

    // ---- BHT update (Lab4) ----
    assign bp_update_valid = idex_is_branch & idex_v & ~mem_stall;
    assign bp_update_taken = jump;

    assign ex_stall = ex_alu_stall | mem_stall;
    assign ex_addr = idex_rs_val + idex_imm;
    assign ex_wdata = idex_dmem_use_be ? {4{idex_rt_val[7:0]}}:idex_rt_val;
    assign ex_is_branch = idex_is_branch & idex_v;
    wire [3:0]ex_be;
    reg [3:0]exmem_be;
    assign ex_be = (~idex_dmem_use_be)?4'b0000:
                (~|(ex_addr[1:0] ^ 2'b00))?   4'b1110:
                (~|(ex_addr[1:0] ^ 2'b01))?   4'b1101:
                (~|(ex_addr[1:0] ^ 2'b10))?   4'b1011:
                                                4'b0111;
    always @(posedge clk)begin
        if(rst)begin
            exmem_v <= 1'b0;
        end
        else if(mem_stall)begin
            exmem_v <= exmem_v;
        end
        else if(~mem_stall)begin
            if(fit && ~idex_reg_w)begin
                // Kill pure branch (BEQ,BNE,J,JR,BGEZ,BGTZ,BLEZ,BLTZ)
                // in MEM -- no register or memory side effects.
                // JAL/JALR (idex_reg_w=1) must reach WB to write return address.
                exmem_v <= 1'b0;
            end
            else if(ex_stall)begin
                exmem_v <= 1'b0;
            end else begin
                exmem_v <= idex_v;
            end
        end
    end
    always@(posedge clk)begin
        if(rst)begin
            exmem_alu_out <= 32'b0;
            exmem_addr <= 32'b0;
            exmem_wdata <= 32'b0;
            exmem_dmem_r <= 1'b0;
            exmem_dmem_w <= 1'b0;
            exmem_reg_w <= 1'b0;
            exmem_rd <= 5'b0;
            exmem_datatoreg <= 1'b0;
            exmem_be <= 4'b0;
        end else if(mem_stall)begin
            exmem_alu_out <= exmem_alu_out;
            exmem_addr <= exmem_addr;
            exmem_wdata <= exmem_wdata;
            exmem_dmem_r <= exmem_dmem_r;
            exmem_dmem_w <= exmem_dmem_w;
            exmem_reg_w <= exmem_reg_w;
            exmem_rd <= exmem_rd;
            exmem_datatoreg <= exmem_datatoreg;
            exmem_be <= exmem_be;
        end else if(~mem_stall)begin
            exmem_alu_out <= ex_alu_out;
            exmem_addr <= ex_addr;
            exmem_wdata <= ex_wdata;
            exmem_dmem_r <= idex_dmem_r;
            exmem_dmem_w <= idex_dmem_w;
            exmem_reg_w <= idex_reg_w;
            exmem_rd <= idex_rd;
            exmem_datatoreg <= idex_datatoreg;
            exmem_be <= ex_be;
        end
    end
    
    assign be = exmem_be;
    assign dmem_wdata = exmem_wdata;
    assign dmem_addr = exmem_addr;
    assign dmem_w = exmem_dmem_w&exmem_v;
    assign dmem_r = exmem_dmem_r&exmem_v;
    assign data_req = dmem_w | dmem_r;
    assign data_we = dmem_w;
    assign data_re = dmem_r;
    assign inst_req = ~rst;
    assign dmem_rdata_be =  (~|(be))? dmem_rdata:
                            (~|(be ^ 4'b1110))? {{24{dmem_rdata[7]}}, dmem_rdata[7:0]}:
                            (~|(be ^ 4'b1101))? {{24{dmem_rdata[15]}}, dmem_rdata[15:8]}:
                            (~|(be ^ 4'b1011))? {{24{dmem_rdata[23]}}, dmem_rdata[23:16]}:
                                                {{24{dmem_rdata[31]}}, dmem_rdata[31:24]};
    wire [31:0]wb_data;
    assign wb_data = exmem_datatoreg?dmem_rdata_be:exmem_alu_out;
    
    always @(posedge clk)begin
        if(rst)begin
            wb_rd <= 5'h0;
            wb_reg_w <= 1'b0;
            wb_reg_wdata <= 32'h0;
        end
        else begin
            if(~mem_stall)begin
                wb_rd <= exmem_rd;
                wb_reg_w <= exmem_reg_w&exmem_v;
                wb_reg_wdata <= wb_data;
            end
        end
    end
endmodule
