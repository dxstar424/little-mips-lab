`timescale 1ns / 1ps
`default_nettype none

// Virtual address -> BaseRAM / ExtRAM chip select and bus mapping.
// 0x8000_0000 - 0x803F_FFFF : BaseRAM (addr[22] == 0)
// 0x8040_0000 - 0x807F_FFFF : ExtRAM  (addr[22] == 1)
// 0xBFD0_03F0 - 0xBFD0_03FF : UART window (placeholder)
module mmap(
    input  wire        txn_active,    // chip selected (READ / WRITE / WAIT)
    input  wire        txn_is_write,  // latched transaction type
    input  wire        in_write_phase,// WE asserted only during S_WRITE
    input  wire [31:0] vaddr,
    input  wire [3:0]  be_n,          // byte enable, active low
    input  wire [31:0] wdata,

    input  wire [31:0] base_ram_data_i,
    input  wire [31:0] ext_ram_data_i,
    output wire [31:0] rdata,

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

    wire sel_ext  = vaddr[22];
    wire sel_uart = (vaddr[31:4] == 28'hbfd003f);

    wire cs_base = txn_active && (~sel_ext) && (~sel_uart);
    wire cs_ext  = txn_active && ( sel_ext) && (~sel_uart);

    assign base_ram_addr = vaddr[21:2];
    assign ext_ram_addr  = vaddr[21:2];

    assign base_ram_be_n = cs_base ? be_n : 4'b1111;
    assign ext_ram_be_n  = cs_ext  ? be_n : 4'b1111;

    assign base_ram_ce_n = ~cs_base;
    assign ext_ram_ce_n  = ~cs_ext;

    // Hold OE low for the entire read burst (READ + WAIT)
    assign base_ram_oe_n = ~((~txn_is_write) && cs_base);
    assign ext_ram_oe_n  = ~((~txn_is_write) && cs_ext);

    // WE_n must stay low through S_WRITE+S_WAIT so it is still 0 when
    // CE_n rises at S_WAIT→IDLE.  The SRAM behavioural model writes at
    // posedge CE_n while WE_n==0.  Using txn_is_write (not in_write_phase)
    // keeps WE_n active for the entire transaction.
    assign base_ram_we_n = ~(txn_is_write && cs_base);
    assign ext_ram_we_n  = ~(txn_is_write && cs_ext);

    // Data bus must be driven through S_WRITE+S_WAIT so it is stable
    // when CE_n rises.  Same reasoning: use txn_is_write, not in_write_phase.
    wire drive_base = txn_is_write && cs_base;
    wire drive_ext  = txn_is_write && cs_ext;
    assign base_ram_data = drive_base ? wdata : 32'bz;
    assign ext_ram_data  = drive_ext  ? wdata : 32'bz;

    assign rdata = sel_ext ? ext_ram_data_i : base_ram_data_i;

endmodule
