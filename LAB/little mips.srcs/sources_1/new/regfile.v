`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/01/13 12:08:24
// Design Name: 
// Module Name: regfile
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module regfile(
    input wire clk,
    input wire rst,
    input wire [4:0]rs,
    input wire [4:0]rt,
    input wire [4:0]rd,
    input wire [31:0]data,
    input wire reg_wen,
    output wire [31:0]rs_val,
    output wire [31:0]rt_val
    );
    reg [31:0]regs[31:0];
    
    wire [31:0]regs_next[31:0];
    assign regs_next[0] = 32'b0;
    
    genvar i;
    generate
        for(i = 1 ; i <= 31 ; i = i +1)begin
            assign regs_next[i]=((~|(rd^i[4:0]))&reg_wen)?data:regs[i];
        end
    endgenerate
    assign rs_val = regs_next[rs];
    assign rt_val = regs_next[rt];
    
    integer j;
    always @(posedge clk)begin
        if(rst)begin
            for (j = 0; j < 32; j = j + 1) begin
                regs[j[4:0]] <= 32'b0;
            end
        end else begin
            for (j = 0; j < 32; j = j + 1) begin
                regs[j[4:0]] <= regs_next[j[4:0]];
            end
        end
    end
endmodule
