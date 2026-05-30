`timescale 1ns / 1ps
`default_nettype none

module MemCtrl(
    input  wire        clk,
    input  wire        rst,

    // ========================= Core-side interface =========================
    input  wire        inst_req,      // IF stage instruction fetch request
    input  wire [31:0] inst_addr,     // IF stage instruction fetch address
    output reg  [31:0] inst_data,     // instruction returned to Core

    input  wire        data_req,      // data memory request (LW/SW/LB/SB)
    input  wire        data_we,       // 1=write, 0=read
    input  wire [3:0]  data_be,       // byte enable (active low, consistent with Core)
    input  wire [31:0] data_addr,     // data memory address
    input  wire [31:0] data_wdata,    // data write value
    output reg  [31:0] data_rdata,    // data read-back value

    output wire        mem_stall,     // global stall signal, active high

    // ========================= Physical chip-side interface =========================
    inout  wire [31:0] base_ram_data,
    output wire [19:0] base_ram_addr,
    output wire [3:0]  base_ram_be_n,
    output wire        base_ram_ce_n,
    output wire        base_ram_oe_n,
    output reg         base_ram_we_n,

    inout  wire [31:0] ext_ram_data,
    output wire [19:0] ext_ram_addr,
    output wire [3:0]  ext_ram_be_n,
    output wire        ext_ram_ce_n,
    output wire        ext_ram_oe_n,
    output reg         ext_ram_we_n
);

    // State machine: IDLE / READ / WRITE / WAIT
    localparam [1:0] S_IDLE  = 2'd0;
    localparam [1:0] S_READ  = 2'd1;
    localparam [1:0] S_WRITE = 2'd2;
    localparam [1:0] S_WAIT  = 2'd3;

    // Wait cycles per device (board-level timing tunable)
    localparam [3:0] WAIT_SRAM = 4'd2;
    localparam [3:0] WAIT_UART = 4'd8;

    reg [1:0] state;
    reg [3:0] wait_cnt;

    // Latch current transaction: no interruption during memory access
    reg        txn_is_inst;
    reg        txn_is_write;
    reg        txn_is_uart;
    reg        txn_use_ext;
    reg [3:0]  txn_be_n;
    reg [31:0] txn_addr;
    reg [31:0] txn_wdata;

    // Address decode: preserve original address mapping
    wire req_data_sel = data_req;
    wire [31:0] req_addr = req_data_sel ? data_addr : inst_addr;
    wire req_is_write = req_data_sel ? data_we : 1'b0;
    wire [3:0] req_be_n = req_data_sel ? data_be : 4'b0000;
    wire [31:0] req_wdata = req_data_sel ? data_wdata : 32'b0;

    wire req_use_ext = req_addr[22];                // 0x8040_0000 window maps to ExtRAM
    wire req_is_uart = (req_addr[31:4] == 28'hbfd003f); // UART window (higher wait cycles)

    wire [31:0] sram_rdata = txn_use_ext ? ext_ram_data : base_ram_data;

    // Arbitration in IDLE: data access prioritized over instruction fetch
    wire any_req = data_req | inst_req;
    wire pick_data = data_req;

    // Stall only when transaction in progress:
    // - After returning to IDLE, stall releases for 1 cycle so Core can latch inst/data
    // - Next cycle, if another request exists, state machine re-enters READ/WRITE and asserts stall
    assign mem_stall = (state != S_IDLE);

    // Data bus: drive during write + 1 extra cycle so DataIO stays valid
    // through the posedge CE_n event (prevents write_data1_time reset race).
    reg  drive_base_r;
    reg  drive_ext_r;
    always @(posedge clk) begin
        if (rst) begin
            drive_base_r <= 1'b0;
            drive_ext_r  <= 1'b0;
        end else begin
            drive_base_r <= txn_is_write && cs_base;
            drive_ext_r  <= txn_is_write && cs_ext;
        end
    end
    assign base_ram_data = (drive_base_r || (txn_is_write && cs_base)) ? txn_wdata : 32'bz;
    assign ext_ram_data  = (drive_ext_r  || (txn_is_write && cs_ext))  ? txn_wdata : 32'bz;

    // RAM control signals (active low)
    wire cs_base = (~txn_use_ext) && (~txn_is_uart) && (state != S_IDLE);
    wire cs_ext  = ( txn_use_ext) && (~txn_is_uart) && (state != S_IDLE);

    assign base_ram_addr = txn_addr[21:2];
    // ExtRAM uses a separate 20-bit address space (0–0xFFFFF).
    // Subtract 0x100000 to map 0x80400000–0x807FFFFF → ExtRAM index 0.
    assign ext_ram_addr  = txn_addr[21:2] - 21'h100000;

    assign base_ram_be_n = cs_base ? txn_be_n : 4'b1111;
    assign ext_ram_be_n  = cs_ext  ? txn_be_n : 4'b1111;

    assign base_ram_ce_n = ~cs_base;
    assign ext_ram_ce_n  = ~cs_ext;

    // Hold OE low during reads (READ+WAIT), prevent bus from going Hi-Z between wait cycles
    assign base_ram_oe_n = ~((~txn_is_write) && cs_base);
    assign ext_ram_oe_n  = ~((~txn_is_write) && cs_ext);

    // WE_n must be registered (one cycle behind CE_n). The SRAM behavioral
    // model writes on posedge CE_n when WE_n==0. Both change on the same
    // posedge if driven combinationally — delaying WE_n ensures CE_n rises
    // while WE_n is still low.
    reg base_ram_we_n;
    reg ext_ram_we_n;
    always @(posedge clk) begin
        if (rst) begin
            base_ram_we_n <= 1'b1;
            ext_ram_we_n  <= 1'b1;
        end else begin
            base_ram_we_n <= ~(txn_is_write && cs_base);
            ext_ram_we_n  <= ~(txn_is_write && cs_ext);
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            state       <= S_IDLE;
            wait_cnt    <= 4'd0;
            txn_is_inst <= 1'b0;
            txn_is_write<= 1'b0;
            txn_is_uart <= 1'b0;
            txn_use_ext <= 1'b0;
            txn_be_n    <= 4'b1111;
            txn_addr    <= 32'b0;
            txn_wdata   <= 32'b0;
            inst_data   <= 32'b0;
            data_rdata  <= 32'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (any_req) begin
                        // Latch the arbitrated transaction; ignore new requests until done
                        txn_is_inst  <= ~pick_data;
                        txn_is_write <= pick_data ? req_is_write : 1'b0;
                        txn_is_uart  <= req_is_uart;
                        txn_use_ext  <= req_use_ext;
                        txn_be_n     <= req_be_n;
                        txn_addr     <= req_addr;
                        txn_wdata    <= req_wdata;

                        if (pick_data ? req_is_write : 1'b0) begin
                            state <= S_WRITE;
                        end else begin
                            state <= S_READ;
                        end
                    end
                end

                S_READ: begin
                    // After initiating read, enter wait cycle
                    wait_cnt <= txn_is_uart ? WAIT_UART : WAIT_SRAM;
                    state <= S_WAIT;
                end

                S_WRITE: begin
                    // After initiating write, enter wait cycle
                    wait_cnt <= txn_is_uart ? WAIT_UART : WAIT_SRAM;
                    state <= S_WAIT;
                end

                S_WAIT: begin
                    if (wait_cnt > 4'd1) begin
                        wait_cnt <= wait_cnt - 4'd1;
                    end else begin
                        // On completion: return read data; write transactions finish without read-back
                        if (~txn_is_write) begin
                            if (txn_is_uart) begin
                                // UART placeholder value; real UART can be connected later
                                if (txn_is_inst) begin
                                    inst_data <= 32'h00000000;
                                end else begin
                                    data_rdata <= 32'h00000000;
                                end
                            end else begin
                                if (txn_is_inst) begin
                                    inst_data <= sram_rdata;
                                end else begin
                                    data_rdata <= sram_rdata;
                                end
                            end
                        end
                        state <= S_IDLE;
                    end
                end

                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
