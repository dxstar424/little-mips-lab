// ALU operation type definitions (Loongson C1/C2/C3 ISA)
// Original instructions (C1 base):
// ADD(4'd0), SUB(4'd1), SLT(4'd2), SLTU(4'd3), AND(4'd4), OR(4'd5), XOR(4'd6), LUI(4'd7)
// SLL(4'd8), SRL(4'd9), SRA(4'd10), RS2(4'd11)
// Extended instructions (Loongson):
// MUL(4'd12) - C3 multiply instruction
`define ADD    4'd0
`define SUB    4'd1
`define SLT    4'd2
`define SLTU   4'd3
`define AND    4'd4
`define OR     4'd5
`define XOR    4'd6
`define LUI    4'd7 // load upper immediate
`define SLL    4'd8
`define SRL    4'd9
`define SRA    4'd10
`define RS2    4'd11 // pass second operand through
`define MUL    4'd12 // Loongson C3 multiply
`define LINK   4'd15 // JAL/JALR return address (PC+8)

// Operand select signals
`define A_RS 2'd0
`define A_PC 2'd1
`define A_SA 2'd2

`define B_RT 2'd0
`define B_SI 2'd1
`define B_8  2'd2


// Branch/jump type definitions (Loongson C1/C2/C3)
// Original branches:
// BEQ(4'd0), BNE(4'd1), BGEZ(4'd2), BGTZ(4'd3), BLEZ(4'd4), BLTZ(4'd5)
// J(4'd6), JAL(4'd7), JR(4'd8), JALR(4'd9), NOP(4'd10)
// Extended branches (Loongson):
// No new branch types; extended existing branch evaluation
`define BEQ     4'd0
`define BNE     4'd1
`define BGEZ    4'd2
`define BGTZ    4'd3
`define BLEZ    4'd4
`define BLTZ    4'd5
`define J       4'd6
`define JAL     4'd7
`define JR      4'd8
`define JALR    4'd9
`define NOP     4'd10

// Loongson C1/C2/C3 instruction set support:
// C1: ORI, ADDU, BNE, LW, SW
// C2: ORI, ADDU, BNE, LW, SW, ANDI, OR, XOR, ADDIU, BEQ, LB, SB
//    + Arithmetic: ADD, ADDI, SUB, SLT
//    + Shifts: SLLV, SRAV, SRA, SRLV
//    + Branches/jumps: JALR, BGEZ, BLEZ, BLTZ
// C3: ADDU, ADDIU, MUL, AND, ANDI, LUI, OR, ORI, XOR, XORI, SLL, SRL,
//     BEQ, BNE, BGTZ, J, JAL, JR, LB, LW

`define IC_NUM 16
`define IC_LEN 4

`define BP_NUM 16
`define BP_LEN 4

`define SRAM_TIME 2'b10 // SRAM requires at least 2 clock cycles per access

// iCache parameters (Lab3)
`define ICACHE_SETS        4    // number of sets (2-bit index)
`define ICACHE_WAYS        4    // 4-way set-associative
`define ICACHE_BLOCK_WORDS 4    // 4 instructions per block (16 bytes)

// BHT parameters (Lab4)
`define BHT_ENTRIES    16   // 16 entries direct-mapped
`define BHT_INDEX_BITS 4    // PC[5:2]
