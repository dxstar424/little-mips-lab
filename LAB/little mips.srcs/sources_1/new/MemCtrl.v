`timescale 1ns / 1ps
`default_nettype none

module MemCtrl(
    input  wire        clk,
    input  wire        rst,

    // ========================= Core-side interface =========================
    input  wire        inst_req,
    input  wire [31:0] inst_addr,
    output reg  [31:0] inst_data,

    input  wire        data_req,
    input  wire        data_we,
    input  wire [3:0]  data_be,
    input  wire [31:0] data_addr,
    input  wire [31:0] data_wdata,
    output reg  [31:0] data_rdata,

    output wire        mem_stall,

    // ========================= Physical chip-side interface =========================
    inout  wire [31:0] base_ram_data,
    output wire [19:0] base_ram_addr,
    output wire [3:0]  base_ram_be_n,
    output wire        base_ram_ce_n,
    output wire        base_ram_oe_n,
    output wire        base_ram_we_n,

    inout  wire [31:0] ext_ram_data,
    output wire [19:0] ext_ram_addr,
    output wire [3:0]  ext_ram_be_n,
    output wire        ext_ram_ce_n,
    output wire        ext_ram_oe_n,
    output wire        ext_ram_we_n
);

    localparam [1:0] S_IDLE  = 2'd0;
    localparam [1:0] S_READ  = 2'd1;
    localparam [1:0] S_WRITE = 2'd2;
    localparam [1:0] S_WAIT  = 2'd3;

    localparam [3:0] WAIT_SRAM = 4'd2;
    localparam [3:0] WAIT_UART = 4'd8;

    reg [1:0] state;
    reg [3:0] wait_cnt;

    // Latched in-flight transaction
    reg        txn_is_inst;
    reg        txn_is_write;
    reg        txn_is_uart;
    reg [3:0]  txn_be_n;
    reg [31:0] txn_addr;
    reg [31:0] txn_wdata;

    // Write buffer (Lab2): accept lone SW without stalling the pipeline
    reg        buf_valid;
    reg        buf_is_uart;
    reg [3:0]  buf_be_n;
    reg [31:0] buf_addr;
    reg [31:0] buf_wdata;

    wire data_read_req  = data_req & (~data_we);
    wire data_write_req = data_req & data_we;

    wire req_is_uart = (data_addr[31:4] == 28'hbfd003f) |
                       (inst_addr[31:4] == 28'hbfd003f);

    wire [31:0] sram_rdata;

    // Lone SW with no competing request can enter the write buffer without stalling
    wire can_buf_write = data_write_req & (~data_read_req) & (~inst_req) &
                         (~buf_valid) & (state == S_IDLE);

    // Priority: data read > data write > buffered write drain > instruction fetch
    wire pick_data_read  = data_read_req;
    wire pick_data_write = (~pick_data_read) & data_write_req & (~can_buf_write);
    wire pick_inst       = (~pick_data_read) & (~pick_data_write) & inst_req;
    wire pick_buf_drain  = (~pick_data_read) & (~pick_data_write) & (~pick_inst) & buf_valid;

    // Stall when a transaction is in flight, or an unserviceable request is waiting.
    // data_read_req stalls immediately (even in IDLE) so MEM-stage LW is not lost
    // before the FSM latches the address on the next posedge.
    assign mem_stall = (state != S_IDLE) |
                       data_read_req |
                       (data_write_req & (~can_buf_write));

    wire txn_active     = (state != S_IDLE);
    wire in_write_phase = (state == S_WRITE);

    mmap u_mmap (
        .txn_active     (txn_active),
        .txn_is_write   (txn_is_write),
        .in_write_phase (in_write_phase),
        .vaddr          (txn_addr),
        .be_n           (txn_be_n),
        .wdata          (txn_wdata),
        .base_ram_data_i(base_ram_data),
        .ext_ram_data_i (ext_ram_data),
        .rdata          (sram_rdata),
        .base_ram_data  (base_ram_data),
        .base_ram_addr  (base_ram_addr),
        .base_ram_be_n  (base_ram_be_n),
        .base_ram_ce_n  (base_ram_ce_n),
        .base_ram_oe_n  (base_ram_oe_n),
        .base_ram_we_n  (base_ram_we_n),
        .ext_ram_data   (ext_ram_data),
        .ext_ram_addr   (ext_ram_addr),
        .ext_ram_be_n   (ext_ram_be_n),
        .ext_ram_ce_n   (ext_ram_ce_n),
        .ext_ram_oe_n   (ext_ram_oe_n),
        .ext_ram_we_n   (ext_ram_we_n)
    );

    always @(posedge clk) begin
        if (rst) begin
            state       <= S_IDLE;
            wait_cnt    <= 4'd0;
            txn_is_inst <= 1'b0;
            txn_is_write<= 1'b0;
            txn_is_uart <= 1'b0;
            txn_be_n    <= 4'b1111;
            txn_addr    <= 32'b0;
            txn_wdata   <= 32'b0;
            inst_data   <= 32'b0;
            data_rdata  <= 32'b0;
            buf_valid   <= 1'b0;
            buf_is_uart <= 1'b0;
            buf_be_n    <= 4'b1111;
            buf_addr    <= 32'b0;
            buf_wdata   <= 32'b0;
        end else begin
            // Accept buffered write without entering the FSM
            if (can_buf_write) begin
                buf_valid   <= 1'b1;
                buf_is_uart <= req_is_uart;
                buf_be_n    <= data_be;
                buf_addr    <= data_addr;
                buf_wdata   <= data_wdata;
            end

            case (state)
                S_IDLE: begin
                    if (pick_data_read) begin
                        txn_is_inst  <= 1'b0;
                        txn_is_write <= 1'b0;
                        txn_is_uart  <= req_is_uart;
                        txn_be_n     <= data_be;
                        txn_addr     <= data_addr;
                        txn_wdata    <= 32'b0;
                        state        <= S_READ;
                    end else if (pick_data_write) begin
                        txn_is_inst  <= 1'b0;
                        txn_is_write <= 1'b1;
                        txn_is_uart  <= req_is_uart;
                        txn_be_n     <= data_be;
                        txn_addr     <= data_addr;
                        txn_wdata    <= data_wdata;
                        state        <= S_WRITE;
                    end else if (pick_inst) begin
                        txn_is_inst  <= 1'b1;
                        txn_is_write <= 1'b0;
                        txn_is_uart  <= req_is_uart;
                        txn_be_n     <= 4'b0000;
                        txn_addr     <= inst_addr;
                        txn_wdata    <= 32'b0;
                        state        <= S_READ;
                    end else if (pick_buf_drain) begin
                        txn_is_inst  <= 1'b0;
                        txn_is_write <= 1'b1;
                        txn_is_uart  <= buf_is_uart;
                        txn_be_n     <= buf_be_n;
                        txn_addr     <= buf_addr;
                        txn_wdata    <= buf_wdata;
                        buf_valid    <= 1'b0;
                        state        <= S_WRITE;
                    end
                end

                S_READ: begin
                    wait_cnt <= txn_is_uart ? WAIT_UART : WAIT_SRAM;
                    state    <= S_WAIT;
                end

                S_WRITE: begin
                    wait_cnt <= txn_is_uart ? WAIT_UART : WAIT_SRAM;
                    state    <= S_WAIT;
                end

                S_WAIT: begin
                    if (wait_cnt > 4'd1) begin
                        wait_cnt <= wait_cnt - 4'd1;
                    end else begin
                        if (~txn_is_write) begin
                            if (txn_is_uart) begin
                                if (txn_is_inst)
                                    inst_data <= 32'h00000000;
                                else
                                    data_rdata <= 32'h00000000;
                            end else begin
                                if (txn_is_inst)
                                    inst_data <= sram_rdata;
                                else
                                    data_rdata <= sram_rdata;
                            end
                        end
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
