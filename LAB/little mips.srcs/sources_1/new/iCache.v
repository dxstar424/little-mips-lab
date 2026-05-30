`timescale 1ns / 1ps
`include "headder.vh"

module iCache #(
    parameter SETS        = `ICACHE_SETS,         // 4
    parameter WAYS        = `ICACHE_WAYS,         // 4
    parameter BLOCK_WORDS = `ICACHE_BLOCK_WORDS   // 4
)(
    input  wire        clk,
    input  wire        rst,

    // ---- Core side ----
    input  wire [31:0] core_pc,
    input  wire        core_inst_req,
    output wire [31:0] core_inst,
    output wire        core_stall,      // combinational: asserted immediately on miss so Core never latches bad inst

    // ---- MemCtrl side ----
    output reg         mem_inst_req,
    output reg  [31:0] mem_inst_addr,
    input  wire [31:0] mem_inst_data,
    input  wire        mem_stall,

    // ---- Bus snoop ----
    input  wire        data_req
);

    // ============================================================
    // Cache storage
    // ============================================================
    reg        valid [0:WAYS-1][0:SETS-1];
    reg [25:0] tag   [0:WAYS-1][0:SETS-1];
    reg [31:0] data  [0:WAYS-1][0:SETS-1][0:BLOCK_WORDS-1];
    reg [1:0]  repl_ctr [0:SETS-1];

    // ============================================================
    // Address field extraction (combinational)
    // ============================================================
    wire [1:0]  id_index = core_pc[5:4];
    wire [25:0] id_tag   = core_pc[31:6];
    wire [1:0]  id_word  = core_pc[3:2];

    // ============================================================
    // Hit detection (combinational, 4-way parallel compare)
    // ============================================================
    wire [WAYS-1:0] way_hit;
    genvar w;
    generate
        for (w = 0; w < WAYS; w = w + 1) begin : hit_gen
            assign way_hit[w] = valid[w][id_index] && (tag[w][id_index] == id_tag);
        end
    endgenerate

    wire cache_hit = |way_hit;

    // ============================================================
    // Hit way selection (priority encoder)
    // ============================================================
    reg [1:0] hit_way;
    integer hw;
    always @(*) begin
        hit_way = 2'd0;
        for (hw = 0; hw < WAYS; hw = hw + 1) begin
            if (way_hit[hw]) hit_way = hw[1:0];
        end
    end

    // ============================================================
    // Data output (combinational)
    // ============================================================
    assign core_inst = cache_hit ? data[hit_way][id_index][id_word] : 32'b0;

    // ============================================================
    // core_stall: combinational, asserted immediately on miss.
    // Stable before Core samples inst on the clock edge, so Core
    // never latches a bogus instruction.
    // ============================================================
    wire miss_detected;
    assign miss_detected = core_inst_req && !cache_hit;
    assign core_stall = (state == S_MISS_FILL) || ((state == S_IDLE) && miss_detected);

    // ============================================================
    // State machine
    // ============================================================
    localparam S_IDLE      = 1'b0;
    localparam S_MISS_FILL = 1'b1;

    reg        state;
    reg [1:0]  fill_cnt;
    reg [31:0] block_base;
    reg [1:0]  repl_way;
    reg [25:0] miss_tag;
    reg [1:0]  miss_index;
    reg        is_our_txn;
    reg [1:0]  stall_cnt;     // count mem_stall cycles for address-advance timing
    integer    rst_w, rst_s;

    // mem_stall edge detection
    reg mem_stall_d;
    wire stall_rise = !mem_stall_d &&  mem_stall;
    wire stall_fall =  mem_stall_d && !mem_stall;

    always @(posedge clk) begin
        mem_stall_d <= mem_stall;
    end

    always @(posedge clk) begin
        if (rst) begin
            state       <= S_IDLE;
            mem_inst_req<= 1'b0;
            mem_inst_addr <= 32'b0;
            fill_cnt    <= 2'd0;
            block_base  <= 32'b0;
            repl_way    <= 2'd0;
            miss_tag    <= 26'd0;
            miss_index  <= 2'd0;
            is_our_txn  <= 1'b0;
            stall_cnt   <= 2'd0;

            for (rst_w = 0; rst_w < WAYS; rst_w = rst_w + 1) begin
                for (rst_s = 0; rst_s < SETS; rst_s = rst_s + 1) begin
                    valid[rst_w][rst_s] <= 1'b0;
                    tag[rst_w][rst_s]   <= 26'd0;
                end
            end
            for (rst_s = 0; rst_s < SETS; rst_s = rst_s + 1) begin
                repl_ctr[rst_s] <= 2'd0;
            end

        end else begin
            case (state)

                S_IDLE: begin
                    mem_inst_req <= 1'b0;
                    is_our_txn   <= 1'b0;
                    stall_cnt    <= 2'd0;

                    if (miss_detected) begin
                        state       <= S_MISS_FILL;
                        fill_cnt    <= 2'd0;
                        block_base  <= {core_pc[31:4], 4'b0};
                        mem_inst_addr <= {core_pc[31:4], 4'b0};
                        mem_inst_req  <= 1'b1;
                        miss_tag      <= id_tag;
                        miss_index    <= id_index;
                        repl_way      <= repl_ctr[id_index];
                        repl_ctr[id_index] <= repl_ctr[id_index] + 2'd1;
                    end
                end

                S_MISS_FILL: begin
                    // Detect ownership of each mem_stall burst.
                    if (stall_rise) begin
                        is_our_txn <= !data_req;
                        if (!data_req) stall_cnt <= 2'd0;
                    end else if (mem_stall && is_our_txn) begin
                        stall_cnt <= stall_cnt + 2'd1;
                    end

                    // Advance address one cycle before stall_fall.
                    // MemCtrl: READ(1) + WAIT(SRAM=2) = 3 stall cycles.
                    // stall_cnt=0 at stall_rise, reaches 1 at the WAIT(cn=1)
                    // cycle. Advancing here means the new address is stable
                    // before MemCtrl samples it on the next IDLE→READ.
                    if (mem_stall && is_our_txn && stall_cnt == 2'd1) begin
                        mem_inst_addr <= block_base + ((fill_cnt + 2'd1) << 2);
                    end

                    // mem_stall falling edge: our transaction completed, data valid.
                    if (stall_fall && is_our_txn) begin
                        data[repl_way][miss_index][fill_cnt] <= mem_inst_data;

                        if (fill_cnt == BLOCK_WORDS - 1) begin
                            // Last word: install tag, return to IDLE
                            valid[repl_way][miss_index] <= 1'b1;
                            tag[repl_way][miss_index]   <= miss_tag;
                            state       <= S_IDLE;
                            mem_inst_req <= 1'b0;
                        end else begin
                            fill_cnt <= fill_cnt + 2'd1;
                        end
                    end
                end

                default: begin
                    state <= S_IDLE;
                end

            endcase
        end
    end

endmodule
