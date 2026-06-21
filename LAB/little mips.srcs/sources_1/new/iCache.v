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
    output wire [31:0] core_inst,       // instruction at core_pc
    output wire [31:0] core_inst_p4,    // instruction at core_pc+4 (Lab5 dual-fetch)
    output wire        core_dual_ok,    // both words hit in cache
    output wire        core_stall,      // combinational: asserted immediately on miss

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

    wire [31:0] pc_p4    = core_pc + 32'd4;
    wire [1:0]  id_index_p4 = pc_p4[5:4];
    wire [25:0] id_tag_p4   = pc_p4[31:6];
    wire [1:0]  id_word_p4  = pc_p4[3:2];

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

    // ---- Hit detection for PC+4 (Lab5) ----
    wire [WAYS-1:0] way_hit_p4;
    generate
        for (w = 0; w < WAYS; w = w + 1) begin : hit_p4_gen
            assign way_hit_p4[w] = valid[w][id_index_p4] && (tag[w][id_index_p4] == id_tag_p4);
        end
    endgenerate
    wire cache_hit_p4 = |way_hit_p4;

    reg [1:0] hit_way_p4;
    integer hwp;
    always @(*) begin
        hit_way_p4 = 2'd0;
        for (hwp = 0; hwp < WAYS; hwp = hwp + 1) begin
            if (way_hit_p4[hwp]) hit_way_p4 = hwp[1:0];
        end
    end

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
    assign core_inst_p4 = cache_hit_p4 ? data[hit_way_p4][id_index_p4][id_word_p4] : 32'b0;
    assign core_dual_ok = cache_hit & cache_hit_p4;

    // ============================================================
    // State machine localparams (declared before use for combinational logic)
    // ============================================================
    localparam S_IDLE      = 1'b0;
    localparam S_MISS_FILL = 1'b1;

    // ============================================================
    // core_stall: combinational, asserted immediately on miss.
    // ============================================================
    wire miss_detected;
    assign miss_detected = core_inst_req && !cache_hit;
    assign core_stall = (state == S_MISS_FILL) || ((state == S_IDLE) && miss_detected);

    reg        state;
    reg [1:0]  fill_cnt;
    reg [31:0] block_base;
    reg [1:0]  repl_way;
    reg [25:0] miss_tag;
    reg [1:0]  miss_index;
    reg        is_our_txn;
    reg [1:0]  stall_cnt;     // count mem_stall cycles for address-advance timing
    reg        word_done;     // prevent double-latching the same fill word
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
            word_done   <= 1'b0;

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
                    word_done    <= 1'b0;

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
                    // ----- transaction ownership -----
                    // masked_data_req guarantees data_req==0 during fill,
                    // so every mem_stall burst belongs to us.
                    if (!is_our_txn)
                        is_our_txn <= 1'b1;

                    // ----- stall cycle counter -----
                    // Reset on stall_rise (new MemCtrl transaction) and on
                    // word completion, so each word's count starts from 0.
                    if (stall_rise) begin
                        stall_cnt <= 2'd0;
                    end else if (mem_stall && is_our_txn && !word_done) begin
                        stall_cnt <= stall_cnt + 2'd1;
                    end

                    // ----- address advance (one cycle before data) -----
                    // Advance at cnt==1 so the new address is stable when
                    // MemCtrl starts the next S_READ.
                    if (mem_stall && is_our_txn && stall_cnt == 2'd1) begin
                        mem_inst_addr <= block_base + ((fill_cnt + 2'd1) << 2);
                    end

                    // ----- data latch -----
                    // SRAM_TIME=2:  READ (1) + WAIT(2) = 3 mem_stall cycles.
                    // Data becomes valid when stall_cnt reaches 2 (cnt=0→READ,
                    // 1→WAIT1, 2→WAIT2 = done), or on stall_fall as back-up
                    // for the first word where timing may differ.
                    if (!word_done && is_our_txn &&
                        ((mem_stall && stall_cnt == 2'd2) || stall_fall)) begin
                        data[repl_way][miss_index][fill_cnt] <= mem_inst_data;
                        word_done   <= 1'b1;

                        if (fill_cnt == BLOCK_WORDS - 1) begin
                            valid[repl_way][miss_index] <= 1'b1;
                            tag[repl_way][miss_index]   <= miss_tag;
                            state       <= S_IDLE;
                            mem_inst_req <= 1'b0;
                            is_our_txn  <= 1'b0;
                            word_done   <= 1'b0;
                        end else begin
                            fill_cnt   <= fill_cnt + 2'd1;
                        end
                    end

                    // ----- next-word setup -----
                    // After latching, wait for mem_stall to go low then high
                    // again (rise of next transaction) before clearing word_done.
                    if (word_done && stall_rise) begin
                        word_done   <= 1'b0;
                        stall_cnt   <= 2'd0;
                    end
                end

                default: begin
                    state <= S_IDLE;
                end

            endcase
        end
    end

endmodule
