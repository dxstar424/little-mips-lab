`timescale 1ns / 1ps
`include "headder.vh"

// Lab5: dual-issue Core — slot0 @ PC, slot1 @ PC+4 (architecturally younger).
module Core(
    input  wire        clk,
    input  wire        rst,
    output wire [31:0] pc_o,
    input  wire [31:0] inst,
    input  wire [31:0] inst_p4,
    input  wire        icache_dual_ok,
    output wire        inst_req,
    output wire        data_req,
    output wire        data_we,
    output wire        data_re,
    output wire        dmem_w,
    output wire        dmem_r,
    output wire [3:0]  be,
    output wire [31:0] dmem_addr,
    output wire [31:0] dmem_wdata,
    input  wire [31:0] dmem_rdata,
    input  wire        mem_stall
);
    // ================================================================
    // IF — PC + dual fetch
    // ================================================================
    reg [31:0] pc;
    reg        pred_delayed_branch;
    reg [31:0] pred_delayed_target;

    wire if_stall;
    wire id_stall;
    wire ex_stall;

    wire        bp_taken;
    wire [31:0] bp_target;
    wire        bp_mispredict;
    wire        bp_update_valid;
    wire        bp_update_taken;

    wire        issue2;
    wire        issue2_ifid;
    wire        issue2_fetch;
    wire        fit;
    wire [31:0] fit_target;
    wire        jump0;
    wire        ex0_actual_taken;

    assign pc_o     = pc;
    assign if_stall = id_stall;
    assign inst_req = ~rst;

    // PC redirect / advance (BHT on slot0 only)
    always @(posedge clk) begin
        if (rst) begin
            pc                   <= 32'h8000_0000;
            pred_delayed_branch  <= 1'b0;
            pred_delayed_target  <= 32'b0;
        end else if (bp_mispredict & (~mem_stall)) begin
            if (ex0_actual_taken)
                pc <= fit_target;
            else
                pc <= idex0_pc + (idex0_issue2 ? 32'd8 : 32'd4);
            pred_delayed_branch <= 1'b0;
        end else if (fit & (~mem_stall) & ~idex0_pred_taken) begin
            pc <= fit_target;
            pred_delayed_branch <= 1'b0;
        end else if ((~if_stall) & (~mem_stall)) begin
            if (pred_delayed_branch) begin
                pc <= pred_delayed_target;
                pred_delayed_branch <= 1'b0;
            end else begin
                if (bp_taken) begin
                    pred_delayed_branch <= 1'b1;
                    pred_delayed_target <= bp_target;
                end
                pc <= pc + (issue2_ifid ? 32'd8 : 32'd4);
            end
        end
    end

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
        .update_pc(idex0_pc),
        .update_taken(bp_update_taken),
        .update_target(fit_target)
    );

    // ================================================================
    // IF/ID — two lanes
    // ================================================================
    reg [31:0] ifid0_pc;
    reg [31:0] ifid0_inst;
    reg        ifid0_v;
    reg        ifid0_pred_taken;
    reg [31:0] ifid0_pred_target;

    reg [31:0] ifid1_pc;
    reg [31:0] ifid1_inst;
    reg        ifid1_v;

    always @(posedge clk) begin
        if (rst) begin
            ifid0_v          <= 1'b0;
            ifid0_pred_taken <= 1'b0;
            ifid0_pred_target<= 32'b0;
            ifid1_v          <= 1'b0;
        end else if (mem_stall) begin
            ifid0_v          <= ifid0_v;
            ifid0_pred_taken <= ifid0_pred_taken;
            ifid0_pred_target<= ifid0_pred_target;
            ifid1_v          <= ifid1_v;
        end else if (bp_mispredict | (fit & ~idex0_pred_taken)) begin
            ifid0_v          <= 1'b0;
            ifid0_pred_taken <= 1'b0;
            ifid0_pred_target<= 32'b0;
            ifid1_v          <= 1'b0;
        end else if (id_stall) begin
            // Load-use stall: insert bubble so stall self-resolves.
            // Unlike mem_stall (freeze), id_stall must clear IF/ID so the
            // LW can leave EX and id_data_stall deasserts next cycle.
            ifid0_v          <= 1'b0;
            ifid1_v          <= 1'b0;
        end else begin
            // Normal advance: no stall, no mispredict
            ifid0_v          <= 1'b1;
            ifid0_pred_taken <= bp_taken;
            ifid0_pred_target<= bp_target;
            ifid1_v          <= issue2_fetch;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            ifid0_pc  <= 32'b0;
            ifid0_inst<= 32'b0;
            ifid1_pc  <= 32'b0;
            ifid1_inst<= 32'b0;
        end else if (mem_stall) begin
            ifid0_pc  <= ifid0_pc;
            ifid0_inst<= ifid0_inst;
            ifid1_pc  <= ifid1_pc;
            ifid1_inst<= ifid1_inst;
        end else if (~id_stall) begin
            ifid0_pc  <= pc;
            ifid0_inst<= inst;
            ifid1_pc  <= pc + 32'd4;
            ifid1_inst<= inst_p4;
        end
    end

    // ================================================================
    // ID — dual decode + dispatch
    // ================================================================
    wire [4:0] id0_rs, id0_rt, id0_rd;
    wire       id0_reg_w, id0_dmem_r, id0_dmem_w, id0_dmem_use_be;
    wire       id0_datatoreg, id0_use_rs, id0_use_rt, id0_is_branch;
    wire [3:0] id0_alu_type, id0_br_type;
    wire [1:0] id0_A, id0_B;
    wire [31:0] id0_imm;

    wire [4:0] id1_rs, id1_rt, id1_rd;
    wire       id1_reg_w, id1_dmem_r, id1_dmem_w, id1_dmem_use_be;
    wire       id1_datatoreg, id1_use_rs, id1_use_rt, id1_is_branch;
    wire [3:0] id1_alu_type, id1_br_type;
    wire [1:0] id1_A, id1_B;
    wire [31:0] id1_imm;

    Decode dec0 (
        .inst(ifid0_inst),
        .rs(id0_rs), .rt(id0_rt), .rd(id0_rd),
        .reg_wen(id0_reg_w),
        .imm(id0_imm),
        .alu_type(id0_alu_type),
        .A(id0_A), .B(id0_B),
        .dmem_ren(id0_dmem_r), .dmem_wen(id0_dmem_w),
        .dmem_use_be(id0_dmem_use_be),
        .br_type(id0_br_type),
        .datatoreg(id0_datatoreg),
        .use_rs(id0_use_rs), .use_rt(id0_use_rt),
        .is_branch_type(id0_is_branch)
    );

    Decode dec1 (
        .inst(ifid1_inst),
        .rs(id1_rs), .rt(id1_rt), .rd(id1_rd),
        .reg_wen(id1_reg_w),
        .imm(id1_imm),
        .alu_type(id1_alu_type),
        .A(id1_A), .B(id1_B),
        .dmem_ren(id1_dmem_r), .dmem_wen(id1_dmem_w),
        .dmem_use_be(id1_dmem_use_be),
        .br_type(id1_br_type),
        .datatoreg(id1_datatoreg),
        .use_rs(id1_use_rs), .use_rt(id1_use_rt),
        .is_branch_type(id1_is_branch)
    );

    // Fetch-time decode (for incoming bundle before IF/ID latch)
    wire [4:0] f0_rs, f0_rt, f0_rd;
    wire       f0_reg_w, f0_dmem_r, f0_dmem_w, f0_is_branch;
    wire [3:0] f0_alu_type;
    wire       f0_use_rs, f0_use_rt;

    wire [4:0] f1_rs, f1_rt, f1_rd;
    wire       f1_reg_w, f1_dmem_r, f1_dmem_w, f1_is_branch;
    wire [3:0] f1_alu_type;
    wire       f1_use_rs, f1_use_rt;

    wire [31:0] f0_imm, f1_imm;
    wire [1:0]  f0_A, f0_B, f1_A, f1_B;
    wire [3:0]  f0_br, f1_br;
    wire        f0_dbe, f1_dbe, f0_dtr, f1_dtr;

    Decode dec_fetch0 (
        .inst(inst),
        .rs(f0_rs), .rt(f0_rt), .rd(f0_rd),
        .reg_wen(f0_reg_w),
        .imm(f0_imm), .alu_type(f0_alu_type),
        .A(f0_A), .B(f0_B),
        .dmem_ren(f0_dmem_r), .dmem_wen(f0_dmem_w),
        .dmem_use_be(f0_dbe),
        .br_type(f0_br), .datatoreg(f0_dtr),
        .use_rs(f0_use_rs), .use_rt(f0_use_rt),
        .is_branch_type(f0_is_branch)
    );

    Decode dec_fetch1 (
        .inst(inst_p4),
        .rs(f1_rs), .rt(f1_rt), .rd(f1_rd),
        .reg_wen(f1_reg_w),
        .imm(f1_imm), .alu_type(f1_alu_type),
        .A(f1_A), .B(f1_B),
        .dmem_ren(f1_dmem_r), .dmem_wen(f1_dmem_w),
        .dmem_use_be(f1_dbe),
        .br_type(f1_br), .datatoreg(f1_dtr),
        .use_rs(f1_use_rs), .use_rt(f1_use_rt),
        .is_branch_type(f1_is_branch)
    );

    dual_engine de_ifid (
        .icache_dual_ok(icache_dual_ok),
        .s0_v(ifid0_v),
        .s0_use_rs(id0_use_rs), .s0_use_rt(id0_use_rt),
        .s0_reg_w(id0_reg_w),
        .s0_dmem_r(id0_dmem_r), .s0_dmem_w(id0_dmem_w),
        .s0_is_branch(id0_is_branch),
        .s0_alu_type(id0_alu_type),
        .s0_rs(id0_rs), .s0_rt(id0_rt), .s0_rd(id0_rd),
        .s1_v(ifid1_v),
        .s1_use_rs(id1_use_rs), .s1_use_rt(id1_use_rt),
        .s1_reg_w(id1_reg_w),
        .s1_dmem_r(id1_dmem_r), .s1_dmem_w(id1_dmem_w),
        .s1_is_branch(id1_is_branch),
        .s1_alu_type(id1_alu_type),
        .s1_rs(id1_rs), .s1_rt(id1_rt), .s1_rd(id1_rd),
        .issue2(issue2_ifid)
    );

    dual_engine de_fetch (
        .icache_dual_ok(icache_dual_ok),
        .s0_v(1'b1),
        .s0_use_rs(f0_use_rs), .s0_use_rt(f0_use_rt),
        .s0_reg_w(f0_reg_w),
        .s0_dmem_r(f0_dmem_r), .s0_dmem_w(f0_dmem_w),
        .s0_is_branch(f0_is_branch),
        .s0_alu_type(f0_alu_type),
        .s0_rs(f0_rs), .s0_rt(f0_rt), .s0_rd(f0_rd),
        .s1_v(icache_dual_ok),
        .s1_use_rs(f1_use_rs), .s1_use_rt(f1_use_rt),
        .s1_reg_w(f1_reg_w),
        .s1_dmem_r(f1_dmem_r), .s1_dmem_w(f1_dmem_w),
        .s1_is_branch(f1_is_branch),
        .s1_alu_type(f1_alu_type),
        .s1_rs(f1_rs), .s1_rt(f1_rt), .s1_rd(f1_rd),
        .issue2(issue2_fetch)
    );

    assign issue2 = issue2_ifid;

    wire [31:0] id0_rs_val, id0_rt_val, id1_rs_val, id1_rt_val;
    wire [31:0] id0_rs_val_f, id0_rt_val_f, id1_rs_val_f, id1_rt_val_f;
    wire        id0_data_stall, id1_data_stall;

    wire id0_lu_stall = id0_data_stall & ifid0_v;
    wire id1_lu_stall = id1_data_stall & ifid1_v & issue2;
    assign id_stall = ex_stall | id0_lu_stall | id1_lu_stall;

    // ================================================================
    // ID/EX — lane0 (master) + lane1 (slave)
    // ================================================================
    reg [31:0] idex0_pc;
    reg [4:0]  idex0_rs, idex0_rt, idex0_rd;
    reg [1:0]  idex0_A, idex0_B;
    reg        idex0_reg_w, idex0_dmem_r, idex0_dmem_w, idex0_dmem_use_be;
    reg        idex0_datatoreg, idex0_use_rs, idex0_use_rt, idex0_is_branch;
    reg [3:0]  idex0_alu_type, idex0_br_type;
    reg [31:0] idex0_imm, idex0_rs_val, idex0_rt_val;
    reg        idex0_v;
    reg        idex0_pred_taken;
    reg [31:0] idex0_pred_target;
    reg        idex0_issue2;

    reg [31:0] idex1_pc;
    reg [4:0]  idex1_rs, idex1_rt, idex1_rd;
    reg [1:0]  idex1_A, idex1_B;
    reg        idex1_reg_w, idex1_dmem_r, idex1_dmem_w, idex1_dmem_use_be;
    reg        idex1_datatoreg;
    reg [3:0]  idex1_alu_type;
    reg [31:0] idex1_imm, idex1_rs_val, idex1_rt_val;
    reg        idex1_v;

    always @(posedge clk) begin
        if (rst) begin
            idex0_v           <= 1'b0;
            idex0_pred_taken  <= 1'b0;
            idex0_pred_target <= 32'b0;
            idex0_issue2      <= 1'b0;
            idex1_v           <= 1'b0;
        end else if (mem_stall) begin
            idex0_v           <= idex0_v;
            idex0_pred_taken  <= idex0_pred_taken;
            idex0_pred_target <= idex0_pred_target;
            idex0_issue2      <= idex0_issue2;
            idex1_v           <= idex1_v;
        end else if (bp_mispredict) begin
            // Keep V bits alive — delay slot must execute.
            idex0_pred_taken  <= 1'b0;
            idex0_pred_target <= 32'b0;
        end else if (id_stall) begin
            // Load-use stall: insert bubble so LW can leave EX.
            // EX/MEM latches idex_v (old=1, LW) → LW enters MEM.
            // Next cycle id_data_stall sees EX bubble → stall resolved.
            idex0_v           <= 1'b0;
            idex1_v           <= 1'b0;
        end else if (~ex_stall) begin
            // Normal advance (id_stall=0, no bp_mispredict)
            idex0_v           <= ifid0_v;
            idex0_pred_taken  <= ifid0_pred_taken;
            idex0_pred_target <= ifid0_pred_target;
            idex0_issue2      <= issue2;
            idex1_v           <= ifid1_v & issue2;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            idex0_pc          <= 32'b0;
            idex0_rs          <= 5'b0;
            idex0_rt          <= 5'b0;
            idex0_rd          <= 5'b0;
            idex0_A           <= 2'b0;
            idex0_B           <= 2'b0;
            idex0_reg_w       <= 1'b0;
            idex0_dmem_r      <= 1'b0;
            idex0_dmem_w      <= 1'b0;
            idex0_dmem_use_be <= 1'b0;
            idex0_datatoreg   <= 1'b0;
            idex0_imm         <= 32'b0;
            idex0_br_type     <= 4'b0;
            idex0_alu_type    <= 4'b0;
            idex0_is_branch   <= 1'b0;
            idex0_rs_val      <= 32'b0;
            idex0_rt_val      <= 32'b0;
            idex1_pc          <= 32'b0;
            idex1_rs          <= 5'b0;
            idex1_rt          <= 5'b0;
            idex1_rd          <= 5'b0;
            idex1_A           <= 2'b0;
            idex1_B           <= 2'b0;
            idex1_reg_w       <= 1'b0;
            idex1_dmem_r      <= 1'b0;
            idex1_dmem_w      <= 1'b0;
            idex1_dmem_use_be <= 1'b0;
            idex1_datatoreg   <= 1'b0;
            idex1_imm         <= 32'b0;
            idex1_alu_type    <= 4'b0;
            idex1_rs_val      <= 32'b0;
            idex1_rt_val      <= 32'b0;
        end else if (mem_stall | id_stall | bp_mispredict) begin
            // Hold during stall, load-use, and branch mispredict.
            // bp_mispredict: ID/EX V bits stay valid (delay slot must execute),
            // but IF/ID is flushed.  We must hold the branch's EX operands
            // instead of latching wrong-path data from the flushed IF/ID.
            idex0_pc          <= idex0_pc;
            idex0_rs          <= idex0_rs;
            idex0_rt          <= idex0_rt;
            idex0_rd          <= idex0_rd;
            idex0_A           <= idex0_A;
            idex0_B           <= idex0_B;
            idex0_reg_w       <= idex0_reg_w;
            idex0_dmem_r      <= idex0_dmem_r;
            idex0_dmem_w      <= idex0_dmem_w;
            idex0_dmem_use_be <= idex0_dmem_use_be;
            idex0_datatoreg   <= idex0_datatoreg;
            idex0_imm         <= idex0_imm;
            idex0_br_type     <= idex0_br_type;
            idex0_alu_type    <= idex0_alu_type;
            idex0_is_branch   <= idex0_is_branch;
            idex0_rs_val      <= idex0_rs_val;
            idex0_rt_val      <= idex0_rt_val;
            idex1_pc          <= idex1_pc;
            idex1_rs          <= idex1_rs;
            idex1_rt          <= idex1_rt;
            idex1_rd          <= idex1_rd;
            idex1_A           <= idex1_A;
            idex1_B           <= idex1_B;
            idex1_reg_w       <= idex1_reg_w;
            idex1_dmem_r      <= idex1_dmem_r;
            idex1_dmem_w      <= idex1_dmem_w;
            idex1_dmem_use_be <= idex1_dmem_use_be;
            idex1_datatoreg   <= idex1_datatoreg;
            idex1_imm         <= idex1_imm;
            idex1_alu_type    <= idex1_alu_type;
            idex1_rs_val      <= idex1_rs_val;
            idex1_rt_val      <= idex1_rt_val;
        end else if (~ex_stall) begin
            idex0_pc          <= ifid0_pc;
            idex0_rs          <= id0_rs;
            idex0_rt          <= id0_rt;
            idex0_rd          <= id0_rd;
            idex0_A           <= id0_A;
            idex0_B           <= id0_B;
            idex0_reg_w       <= id0_reg_w;
            idex0_dmem_r      <= id0_dmem_r;
            idex0_dmem_w      <= id0_dmem_w;
            idex0_dmem_use_be <= id0_dmem_use_be;
            idex0_datatoreg   <= id0_datatoreg;
            idex0_imm         <= id0_imm;
            idex0_br_type     <= id0_br_type;
            idex0_alu_type    <= id0_alu_type;
            idex0_is_branch   <= id0_is_branch;
            idex0_rs_val      <= id0_rs_val_f;
            idex0_rt_val      <= id0_rt_val_f;
            idex1_pc          <= ifid1_pc;
            idex1_rs          <= id1_rs;
            idex1_rt          <= id1_rt;
            idex1_rd          <= id1_rd;
            idex1_A           <= id1_A;
            idex1_B           <= id1_B;
            idex1_reg_w       <= id1_reg_w;
            idex1_dmem_r      <= id1_dmem_r;
            idex1_dmem_w      <= id1_dmem_w;
            idex1_dmem_use_be <= id1_dmem_use_be;
            idex1_datatoreg   <= id1_datatoreg;
            idex1_imm         <= id1_imm;
            idex1_alu_type    <= id1_alu_type;
            idex1_rs_val      <= id1_rs_val_f;
            idex1_rt_val      <= id1_rt_val_f;
        end
    end

    // ================================================================
    // Register file (4R / 2W) + dual forwarding
    // ================================================================
    reg [4:0]  wb0_rd, wb1_rd;
    reg [31:0] wb0_wdata, wb1_wdata;
    reg         wb0_wen, wb1_wen;

    regfile rf (
        .clk(clk), .rst(rst),
        .rs0(id0_rs), .rt0(id0_rt),
        .rs1(id1_rs), .rt1(id1_rt),
        .rd0(wb0_rd), .rd1(wb1_rd),
        .wdata0(wb0_wdata), .wdata1(wb1_wdata),
        .wen0(wb0_wen), .wen1(wb1_wen),
        .rs0_val(id0_rs_val), .rt0_val(id0_rt_val),
        .rs1_val(id1_rs_val), .rt1_val(id1_rt_val)
    );

    wire [31:0] dmem_rdata_be0, dmem_rdata_be1;

    forward_dual fu (
        .id0_rs(id0_rs), .id0_rt(id0_rt),
        .id0_rs_val(id0_rs_val), .id0_rt_val(id0_rt_val),
        .id0_use_rs(id0_use_rs), .id0_use_rt(id0_use_rt),
        .id0_v(ifid0_v),
        .id1_rs(id1_rs), .id1_rt(id1_rt),
        .id1_rs_val(id1_rs_val), .id1_rt_val(id1_rt_val),
        .id1_use_rs(id1_use_rs), .id1_use_rt(id1_use_rt),
        .id1_v(ifid1_v),
        .ex0_v(idex0_v), .ex0_rd(idex0_rd), .ex0_reg_w(idex0_reg_w),
        .ex0_alu_out(ex0_alu_out), .ex0_datatoreg(idex0_datatoreg),
        .ex1_v(idex1_v), .ex1_rd(idex1_rd), .ex1_reg_w(idex1_reg_w),
        .ex1_alu_out(ex1_alu_out), .ex1_datatoreg(idex1_datatoreg),
        .mem0_v(exmem0_v), .mem0_rd(exmem0_rd), .mem0_reg_w(exmem0_reg_w),
        .mem0_alu_out(exmem0_alu_out), .mem0_datatoreg(exmem0_datatoreg),
        .dmem0_rdata(dmem_rdata_be0),
        .mem1_v(exmem1_v), .mem1_rd(exmem1_rd), .mem1_reg_w(exmem1_reg_w),
        .mem1_alu_out(exmem1_alu_out), .mem1_datatoreg(exmem1_datatoreg),
        .dmem1_rdata(dmem_rdata_be1),
        .id0_rs_val_f(id0_rs_val_f), .id0_rt_val_f(id0_rt_val_f),
        .id1_rs_val_f(id1_rs_val_f), .id1_rt_val_f(id1_rt_val_f),
        .id0_data_stall(id0_data_stall), .id1_data_stall(id1_data_stall)
    );

    // ================================================================
    // EX — dual ALU (branches/jumps slot0 only)
    // ================================================================
    wire [31:0] alu0_a_val, alu0_b_val, alu1_a_val, alu1_b_val;
    wire [31:0] ex0_alu_out, ex1_alu_out;
    wire        ex0_alu_stall, ex1_alu_stall;
    wire        jump1_unused;
    wire [31:0] branch1_unused;
    wire [31:0] ex0_addr, ex1_addr;
    wire [31:0] ex0_wdata, ex1_wdata;
    wire [3:0]  ex0_be, ex1_be;

    assign alu0_a_val = ~|(idex0_A ^ `A_RS) ? idex0_rs_val :
                        ~|(idex0_A ^ `A_PC) ? idex0_pc : idex0_imm;
    assign alu0_b_val = ~|(idex0_B ^ `B_SI) ? idex0_imm :
                        ~|(idex0_B ^ `B_RT) ? idex0_rt_val : 32'h8;
    assign alu1_a_val = ~|(idex1_A ^ `A_RS) ? idex1_rs_val :
                        ~|(idex1_A ^ `A_PC) ? idex1_pc : idex1_imm;
    assign alu1_b_val = ~|(idex1_B ^ `B_SI) ? idex1_imm :
                        ~|(idex1_B ^ `B_RT) ? idex1_rt_val : 32'h8;

    assign ex_stall = ex0_alu_stall | ex1_alu_stall | mem_stall;

    ALU alu0 (
        .clk(clk), .rst(rst),
        .a(alu0_a_val), .b(alu0_b_val),
        .alu_type(idex0_alu_type),
        .valid(idex0_v),
        .ex_stall(ex_stall),
        .mem_stall(mem_stall),
        .out_res(ex0_alu_out),
        .alu_stall(ex0_alu_stall),
        .br_type(idex0_br_type),
        .jump(jump0),
        .pc(idex0_pc),
        .rs_v(idex0_rs_val),
        .imm(idex0_imm),
        .branch(fit_target)
    );

    ALU alu1 (
        .clk(clk), .rst(rst),
        .a(alu1_a_val), .b(alu1_b_val),
        .alu_type(idex1_alu_type),
        .valid(idex1_v),
        .ex_stall(ex_stall),
        .mem_stall(mem_stall),
        .out_res(ex1_alu_out),
        .alu_stall(ex1_alu_stall),
        .br_type(4'b0),
        .jump(jump1_unused),
        .pc(idex1_pc),
        .rs_v(idex1_rs_val),
        .imm(idex1_imm),
        .branch(branch1_unused)
    );

    assign fit              = jump0 & idex0_v;
    assign ex0_actual_taken = jump0 & idex0_v;
    assign bp_mispredict    = idex0_is_branch & idex0_v &
        ((idex0_pred_taken != ex0_actual_taken) |
         (idex0_pred_taken & ex0_actual_taken &
          (idex0_pred_target != fit_target)));
    assign bp_update_valid  = idex0_is_branch & idex0_v & ~mem_stall;
    assign bp_update_taken  = jump0;

    assign ex0_addr  = idex0_rs_val + idex0_imm;
    assign ex1_addr  = idex1_rs_val + idex1_imm;
    assign ex0_wdata = idex0_dmem_use_be ? {4{idex0_rt_val[7:0]}} : idex0_rt_val;
    assign ex1_wdata = idex1_dmem_use_be ? {4{idex1_rt_val[7:0]}} : idex1_rt_val;

    assign ex0_be = (~idex0_dmem_use_be) ? 4'b0000 :
                    (~|(ex0_addr[1:0] ^ 2'b00)) ? 4'b1110 :
                    (~|(ex0_addr[1:0] ^ 2'b01)) ? 4'b1101 :
                    (~|(ex0_addr[1:0] ^ 2'b10)) ? 4'b1011 : 4'b0111;
    assign ex1_be = (~idex1_dmem_use_be) ? 4'b0000 :
                    (~|(ex1_addr[1:0] ^ 2'b00)) ? 4'b1110 :
                    (~|(ex1_addr[1:0] ^ 2'b01)) ? 4'b1101 :
                    (~|(ex1_addr[1:0] ^ 2'b10)) ? 4'b1011 : 4'b0111;

    // ================================================================
    // EX/MEM — two lanes
    // ================================================================
    reg [31:0] exmem0_alu_out, exmem0_addr, exmem0_wdata;
    reg        exmem0_dmem_r, exmem0_dmem_w, exmem0_reg_w, exmem0_datatoreg;
    reg [4:0]  exmem0_rd;
    reg [3:0]  exmem0_be;
    reg        exmem0_v;

    reg [31:0] exmem1_alu_out, exmem1_addr, exmem1_wdata;
    reg        exmem1_dmem_r, exmem1_dmem_w, exmem1_reg_w, exmem1_datatoreg;
    reg [4:0]  exmem1_rd;
    reg [3:0]  exmem1_be;
    reg        exmem1_v;

    always @(posedge clk) begin
        if (rst)
            exmem0_v <= 1'b0;
        else if (mem_stall)
            exmem0_v <= exmem0_v;
        else if (~mem_stall) begin
            if (fit & ~idex0_reg_w & ~exmem0_reg_w & ~exmem0_dmem_w & ~exmem0_dmem_r)
                exmem0_v <= 1'b0;
            else if (ex_stall)
                exmem0_v <= 1'b0;
            else
                exmem0_v <= idex0_v;
        end
    end

    always @(posedge clk) begin
        if (rst)
            exmem1_v <= 1'b0;
        else if (mem_stall)
            exmem1_v <= exmem1_v;
        else if (~mem_stall) begin
            if (ex_stall)
                exmem1_v <= 1'b0;
            else
                exmem1_v <= idex1_v;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            exmem0_alu_out    <= 32'b0;
            exmem0_addr       <= 32'b0;
            exmem0_wdata      <= 32'b0;
            exmem0_dmem_r     <= 1'b0;
            exmem0_dmem_w     <= 1'b0;
            exmem0_reg_w      <= 1'b0;
            exmem0_rd         <= 5'b0;
            exmem0_datatoreg  <= 1'b0;
            exmem0_be         <= 4'b0;
            exmem1_alu_out    <= 32'b0;
            exmem1_addr       <= 32'b0;
            exmem1_wdata      <= 32'b0;
            exmem1_dmem_r     <= 1'b0;
            exmem1_dmem_w     <= 1'b0;
            exmem1_reg_w      <= 1'b0;
            exmem1_rd         <= 5'b0;
            exmem1_datatoreg  <= 1'b0;
            exmem1_be         <= 4'b0;
        end else if (mem_stall) begin
            exmem0_alu_out    <= exmem0_alu_out;
            exmem0_addr       <= exmem0_addr;
            exmem0_wdata      <= exmem0_wdata;
            exmem0_dmem_r     <= exmem0_dmem_r;
            exmem0_dmem_w     <= exmem0_dmem_w;
            exmem0_reg_w      <= exmem0_reg_w;
            exmem0_rd         <= exmem0_rd;
            exmem0_datatoreg  <= exmem0_datatoreg;
            exmem0_be         <= exmem0_be;
            exmem1_alu_out    <= exmem1_alu_out;
            exmem1_addr       <= exmem1_addr;
            exmem1_wdata      <= exmem1_wdata;
            exmem1_dmem_r     <= exmem1_dmem_r;
            exmem1_dmem_w     <= exmem1_dmem_w;
            exmem1_reg_w      <= exmem1_reg_w;
            exmem1_rd         <= exmem1_rd;
            exmem1_datatoreg  <= exmem1_datatoreg;
            exmem1_be         <= exmem1_be;
        end else if (~mem_stall) begin
            exmem0_alu_out    <= ex0_alu_out;
            exmem0_addr       <= ex0_addr;
            exmem0_wdata      <= ex0_wdata;
            exmem0_dmem_r     <= idex0_dmem_r;
            exmem0_dmem_w     <= idex0_dmem_w;
            exmem0_reg_w      <= idex0_reg_w;
            exmem0_rd         <= idex0_rd;
            exmem0_datatoreg  <= idex0_datatoreg;
            exmem0_be         <= ex0_be;
            exmem1_alu_out    <= ex1_alu_out;
            exmem1_addr       <= ex1_addr;
            exmem1_wdata      <= ex1_wdata;
            exmem1_dmem_r     <= idex1_dmem_r;
            exmem1_dmem_w     <= idex1_dmem_w;
            exmem1_reg_w      <= idex1_reg_w;
            exmem1_rd         <= idex1_rd;
            exmem1_datatoreg  <= idex1_datatoreg;
            exmem1_be         <= ex1_be;
        end
    end

    // ================================================================
    // MEM — single-port mux (lane0 priority)
    // ================================================================
    wire mem0_active = exmem0_v & (exmem0_dmem_r | exmem0_dmem_w);
    wire mem1_active = exmem1_v & (exmem1_dmem_r | exmem1_dmem_w);
    wire sel_mem0    = mem0_active;

    assign dmem_w    = sel_mem0 ? (exmem0_dmem_w & exmem0_v) :
                                 (exmem1_dmem_w & exmem1_v);
    assign dmem_r    = sel_mem0 ? (exmem0_dmem_r & exmem0_v) :
                                 (exmem1_dmem_r & exmem1_v);
    assign data_req  = mem0_active | mem1_active;
    assign data_we   = dmem_w;
    assign data_re   = dmem_r;
    assign dmem_addr = sel_mem0 ? exmem0_addr : exmem1_addr;
    assign dmem_wdata= sel_mem0 ? exmem0_wdata : exmem1_wdata;
    assign be        = sel_mem0 ? exmem0_be : exmem1_be;

    function [31:0] dmem_byte_extract;
        input [3:0]  be_val;
        input [31:0] rdata;
        begin
            if (~|(be_val))
                dmem_byte_extract = rdata;
            else if (~|(be_val ^ 4'b1110))
                dmem_byte_extract = {{24{rdata[7]}}, rdata[7:0]};
            else if (~|(be_val ^ 4'b1101))
                dmem_byte_extract = {{24{rdata[15]}}, rdata[15:8]};
            else if (~|(be_val ^ 4'b1011))
                dmem_byte_extract = {{24{rdata[23]}}, rdata[23:16]};
            else
                dmem_byte_extract = {{24{rdata[31]}}, rdata[31:24]};
        end
    endfunction

    assign dmem_rdata_be0 = dmem_byte_extract(exmem0_be, dmem_rdata);
    assign dmem_rdata_be1 = dmem_byte_extract(exmem1_be, dmem_rdata);

    // ================================================================
    // WB — dual writeback
    // ================================================================
    wire [31:0] wb0_data = exmem0_datatoreg ? dmem_rdata_be0 : exmem0_alu_out;
    wire [31:0] wb1_data = exmem1_datatoreg ? dmem_rdata_be1 : exmem1_alu_out;

    always @(posedge clk) begin
        if (rst) begin
            wb0_rd    <= 5'b0;
            wb0_wen   <= 1'b0;
            wb0_wdata <= 32'b0;
            wb1_rd    <= 5'b0;
            wb1_wen   <= 1'b0;
            wb1_wdata <= 32'b0;
        end else if (~mem_stall) begin
            wb0_rd    <= exmem0_rd;
            wb0_wen   <= exmem0_reg_w & exmem0_v;
            wb0_wdata <= wb0_data;
            wb1_rd    <= exmem1_rd;
            wb1_wen   <= exmem1_reg_w & exmem1_v;
            wb1_wdata <= wb1_data;
        end
    end

endmodule
