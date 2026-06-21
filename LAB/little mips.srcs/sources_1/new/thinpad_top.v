`default_nettype none
`include "headder.vh"

module thinpad_top(
    input wire clk_50M,           // 50MHz clock input
    input wire clk_11M0592,       // 11.0592MHz clock input

    input wire clock_btn,         // BTN5 manual clock button, debounced, 1 when pressed
    input wire reset_btn,         // BTN6 manual reset button, debounced, 1 when pressed

    input  wire[3:0]  touch_btn,  // BTN1~BTN4 push buttons, 1 when pressed
    input  wire[31:0] dip_sw,     // 32-bit DIP switch, 1 when ON
    output wire[15:0] leds,       // 16-bit LED, lit when output is 1
    output wire[7:0]  dpy0,       // 7-seg display low digit, incl. decimal point, lit when 1
    output wire[7:0]  dpy1,       // 7-seg display high digit, incl. decimal point, lit when 1


    // BaseRAM signals
    inout wire[31:0] base_ram_data,  // BaseRAM data, low 8 bits shared with CPLD UART controller
    output wire[19:0] base_ram_addr, // BaseRAM address
    output wire[3:0] base_ram_be_n,  // BaseRAM byte enable, active low. Keep 0 if unused
    output wire base_ram_ce_n,       // BaseRAM chip select, active low
    output wire base_ram_oe_n,       // BaseRAM read enable, active low
    output wire base_ram_we_n,       // BaseRAM write enable, active low

    // ExtRAM signals
    inout wire[31:0] ext_ram_data,  // ExtRAM data
    output wire[19:0] ext_ram_addr, // ExtRAM address
    output wire[3:0] ext_ram_be_n,  // ExtRAM byte enable, active low. Keep 0 if unused
    output wire ext_ram_ce_n,       // ExtRAM chip select, active low
    output wire ext_ram_oe_n,       // ExtRAM read enable, active low
    output wire ext_ram_we_n,       // ExtRAM write enable, active low

    // Direct UART signals
    output wire txd,  // UART TX
    input  wire rxd,  // UART RX

    // Flash signals, refer to JS28F640 datasheet
    output wire [22:0]flash_a,      // Flash address, a0 valid only in 8-bit mode
    inout  wire [15:0]flash_d,      // Flash data
    output wire flash_rp_n,         // Flash reset, active low
    output wire flash_vpen,         // Flash write protect, erase/program disabled when low
    output wire flash_ce_n,         // Flash chip select, active low
    output wire flash_oe_n,         // Flash read enable, active low
    output wire flash_we_n,         // Flash write enable, active low
    output wire flash_byte_n,       // Flash 8-bit mode select, active low. Set to 1 for 16-bit mode

    // Video output signals
    output wire[2:0] video_red,    // Red pixel, 3-bit
    output wire[2:0] video_green,  // Green pixel, 3-bit
    output wire[1:0] video_blue,   // Blue pixel, 2-bit
    output wire video_hsync,       // Horizontal sync
    output wire video_vsync,       // Vertical sync
    output wire video_clk,         // Pixel clock output
    output wire video_de           // Data enable, distinguishes blanking region
);

    wire clk;
    wire rst;
    assign clk = clk_50M;
    assign rst = reset_btn;
    wire [31:0] pc;
    wire [31:0] inst;
    wire [31:0] inst_p4;
    wire        icache_dual_ok;
    wire inst_req;
    wire data_req;
    wire data_we;
    wire data_re;
    wire dmem_w;
    wire dmem_r;
    wire [3:0]be;
    wire [31:0]dmem_addr;
    wire [31:0]dmem_wdata;
    wire [31:0]dmem_rdata;
    wire mem_stall;
    // iCache signals (added in Lab3)
    wire [31:0] icache_rdata;
    wire        icache_stall;
    wire        icache_inst_req;
    wire [31:0] icache_inst_addr;
    wire        total_mem_stall;

    // masked_data_req: suppress data_req during iCache fill to prevent deadlock.
    // Without this, a LW/SW frozen in MEM keeps data_req=1, MemCtrl keeps
    // servicing it, and iCache fill can never acquire the bus.
    wire        masked_data_req;
    assign masked_data_req = data_req & ~icache_stall;

    assign total_mem_stall = mem_stall | icache_stall;

    Core core(
    .clk(clk),
    .rst(rst),
    .pc_o(pc),
    .inst(inst),
    .inst_p4(inst_p4),
    .icache_dual_ok(icache_dual_ok),
    .inst_req(inst_req),
    .data_req(data_req),
    .data_we(data_we),
    .data_re(data_re),
    .dmem_w(dmem_w),
    .dmem_r(dmem_r),
    .be(be),
    .dmem_addr(dmem_addr),
    .dmem_wdata(dmem_wdata),
    .dmem_rdata(dmem_rdata),
    .mem_stall(total_mem_stall)
    );

    // =========================================================
    // Lab3: iCache inserted between Core and MemCtrl on the instruction path
    // - Hit: iCache outputs inst directly, bypassing MemCtrl
    // - Miss: iCache fills cache line word-by-word through MemCtrl
    // =========================================================
    iCache #(
        .SETS(`ICACHE_SETS),
        .WAYS(`ICACHE_WAYS),
        .BLOCK_WORDS(`ICACHE_BLOCK_WORDS)
    ) icache_inst (
        .clk(clk),
        .rst(rst),
        .core_pc(pc),
        .core_inst_req(inst_req),
        .core_inst(inst),
        .core_inst_p4(inst_p4),
        .core_dual_ok(icache_dual_ok),
        .core_stall(icache_stall),
        .mem_inst_req(icache_inst_req),
        .mem_inst_addr(icache_inst_addr),
        .mem_inst_data(icache_rdata),
        .mem_stall(mem_stall),
        .data_req(masked_data_req)
    );

    // =========================================================
    // Lab2: MemCtrl handles multi-cycle memory access with physical timing
    // =========================================================
    MemCtrl memctrl (
        .clk(clk),
        .rst(rst),
        .inst_req(icache_inst_req),
        .inst_addr(icache_inst_addr),
        .inst_data(icache_rdata),
        .data_req(masked_data_req),
        .data_we(data_we),
        .data_be(be),
        .data_addr(dmem_addr),
        .data_wdata(dmem_wdata),
        .data_rdata(dmem_rdata),
        .mem_stall(mem_stall),

        .base_ram_data(base_ram_data),
        .base_ram_addr(base_ram_addr),
        .base_ram_be_n(base_ram_be_n),
        .base_ram_ce_n(base_ram_ce_n),
        .base_ram_oe_n(base_ram_oe_n),
        .base_ram_we_n(base_ram_we_n),

        .ext_ram_data(ext_ram_data),
        .ext_ram_addr(ext_ram_addr),
        .ext_ram_be_n(ext_ram_be_n),
        .ext_ram_ce_n(ext_ram_ce_n),
        .ext_ram_oe_n(ext_ram_oe_n),
        .ext_ram_we_n(ext_ram_we_n)
    );
endmodule
