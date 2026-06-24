`timescale 1ns / 1ps
`include "headder.vh"

// Dual-issue dispatch logic (Lab5).
// Slot0 = PC, slot1 = PC+4 (architecturally younger).
module dual_engine(
    input  wire        icache_dual_ok,  // both fetch words hit in iCache

    // Slot0 (master) decode
    input  wire        s0_v,
    input  wire        s0_use_rs,
    input  wire        s0_use_rt,
    input  wire        s0_reg_w,
    input  wire        s0_dmem_r,
    input  wire        s0_dmem_w,
    input  wire        s0_is_branch,
    input  wire [3:0]  s0_alu_type,
    input  wire [4:0]  s0_rs,
    input  wire [4:0]  s0_rt,
    input  wire [4:0]  s0_rd,

    // Slot1 (slave) decode
    input  wire        s1_v,
    input  wire        s1_use_rs,
    input  wire        s1_use_rt,
    input  wire        s1_reg_w,
    input  wire        s1_dmem_r,
    input  wire        s1_dmem_w,
    input  wire        s1_is_branch,
    input  wire [3:0]  s1_alu_type,
    input  wire [4:0]  s1_rs,
    input  wire [4:0]  s1_rt,
    input  wire [4:0]  s1_rd,

    output wire        issue2
);

    wire s0_mem = s0_dmem_r | s0_dmem_w;
    wire s1_mem = s1_dmem_r | s1_dmem_w;
    wire s0_mul = ~|(s0_alu_type ^ `MUL);
    wire s1_mul = ~|(s1_alu_type ^ `MUL);

    // Intra-bundle RAW: slot1 reads a register slot0 writes this cycle
    wire raw_rs = s0_reg_w & (s0_rd != 5'd0) & s1_use_rs & (s0_rd == s1_rs);
    wire raw_rt = s0_reg_w & (s0_rd != 5'd0) & s1_use_rt & (s0_rd == s1_rt);
    wire intra_raw = raw_rs | raw_rt;

    // Slot0 load -> slot1 cannot issue in the same bundle
    wire load_use_pair = s0_dmem_r & s1_v &
        ((s1_use_rs & (s0_rd == s1_rs) & (s0_rd != 5'd0)) |
         (s1_use_rt & (s0_rd == s1_rt) & (s0_rd != 5'd0)));

    // Branch in slot0 must take slot1 as delay slot when slot1 is valid
    wire branch_pair = s0_is_branch & s1_v & (~s1_is_branch) & (~s1_mul);

    wire s1_legal = s1_v & (~s1_is_branch) & (~s1_mul);

    wire pair_ok = s0_v & s1_legal & icache_dual_ok &
                   (~(s0_mem & s1_mem)) &
                   (~s0_mul) &
                   (~intra_raw) &
                   (~load_use_pair);

    // Force dual issue for branch + delay slot; otherwise issue when safe
    assign issue2 = branch_pair | (pair_ok & (~s0_is_branch));

endmodule
