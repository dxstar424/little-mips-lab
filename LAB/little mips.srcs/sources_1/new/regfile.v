`timescale 1ns / 1ps

// Dual-issue register file: 4 read ports + 2 write ports (Lab5).
// Program-order younger write (port1 / slot1) wins on same-rd collision.
module regfile(
    input  wire        clk,
    input  wire        rst,

    input  wire [4:0]  rs0,
    input  wire [4:0]  rt0,
    input  wire [4:0]  rs1,
    input  wire [4:0]  rt1,

    input  wire [4:0]  rd0,
    input  wire [4:0]  rd1,
    input  wire [31:0] wdata0,
    input  wire [31:0] wdata1,
    input  wire        wen0,
    input  wire        wen1,

    output wire [31:0] rs0_val,
    output wire [31:0] rt0_val,
    output wire [31:0] rs1_val,
    output wire [31:0] rt1_val
);
    reg [31:0] regs[31:0];

    wire [31:0] regs_next[31:0];
    assign regs_next[0] = 32'b0;

    genvar i;
    generate
        for (i = 1; i <= 31; i = i + 1) begin : reg_write
            wire sel0 = wen0 & (~|(rd0 ^ i[4:0]));
            wire sel1 = wen1 & (~|(rd1 ^ i[4:0]));
            assign regs_next[i] = sel1 ? wdata1 :
                                  sel0 ? wdata0 :
                                         regs[i];
        end
    endgenerate

    function [31:0] read_bypass;
        input [4:0]  raddr;
        input [31:0] rraw;
        begin
            if (raddr == 5'd0)
                read_bypass = 32'b0;
            else if (wen1 && (rd1 == raddr))
                read_bypass = wdata1;
            else if (wen0 && (rd0 == raddr))
                read_bypass = wdata0;
            else
                read_bypass = rraw;
        end
    endfunction

    assign rs0_val = read_bypass(rs0, regs_next[rs0]);
    assign rt0_val = read_bypass(rt0, regs_next[rt0]);
    assign rs1_val = read_bypass(rs1, regs_next[rs1]);
    assign rt1_val = read_bypass(rt1, regs_next[rt1]);

    integer j;
    always @(posedge clk) begin
        if (rst) begin
            for (j = 0; j < 32; j = j + 1)
                regs[j[4:0]] <= 32'b0;
        end else begin
            for (j = 1; j < 32; j = j + 1)
                regs[j[4:0]] <= regs_next[j[4:0]];
        end
    end
endmodule
