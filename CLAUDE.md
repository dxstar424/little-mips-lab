# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A 5-stage pipelined MIPS-compatible CPU (Little MIPS) supporting the Loongson C1/C2/C3 instruction set, implemented in mixed Verilog/VHDL for Xilinx FPGA on a Thinpad educational board. Built with Vivado IDE.

## Build & Simulation

- **IDE**: Vivado 2019 (project-based — open the `.xpr` file or create a new RTL project). No CLI build commands.
- **Target FPGA**: xc7k70tfbv676-1
- **Simulation**: Vivado XSim via GUI. Testbench: `tb.sv`. Simulation models (SRAM, CPLD, flash, clock) live in `sim_1/new/`.
- **IP cores**: Xilinx `mult_gen_0` (signed 32x32 to 64 multiplier) instantiated in `alu.vhd`. Sources under `sources_1/ip/mult_gen_0/`.
- **Setup steps**:
  1. Create Vivado RTL project targeting `xc7k70tfbv676-1`
  2. Add Design Sources: all `.v` and `.vhd` files from `learn/` (or `LAB/little mips.srcs/sources_1/new/`) plus the multiplier IP core
  3. Add Simulation Sources: `tb.sv`
  4. In `tb.sv`, set `BASE_RAM_INIT_FILE` to the absolute path of `labf.bin` or `testfile.bin`
  5. Run Behavioral Simulation; add `tb/dut/core/ref/regs` to wave window
- **Test files**: `LAB/labf.bin` and `LAB/testfile.bin` — correct register values documented in `docs/lab1/requirements.md`

## Top-Level Hierarchy (`thinpad_top.v` / `dpad_top.v`)

```
thinpad_top (clk_50M, reset_btn -> clk/rst)
  ├── Core (pipeline + regfile + decode + forward + ALU)
  ├── iCache (between Core.inst_req and MemCtrl.inst_req)
  └── MemCtrl (multiplexes iCache instruction fetch + Core data access -> physical SRAM)
```

`total_mem_stall = mem_stall | icache_stall` — this combined signal freezes the entire Core pipeline.

## Architecture

### Pipeline: IF -> ID -> EX -> MEM -> WB

| Stage | Pipeline Register | Key Modules |
|-------|-------------------|-------------|
| IF | `pc`, `ifid_*` (PC, inst, valid, pred_taken, pred_target) | `iCache`, `branch_predictor` (BHT lookup) |
| ID | `idex_*` (includes pred_taken, pred_target) | `Decode`, `regfile`, `forward` |
| EX | `exmem_*` | `ALU` (VHDL, includes Xilinx `mult_gen_0` IP for signed MUL) |
| MEM | — (outputs driven directly from `exmem_*`) | `MemCtrl` (state machine: IDLE->READ/WRITE->WAIT) |
| WB | `wb_*` (rd, reg_wdata, reg_w) | Writeback to `regfile` |

Each pipeline register has a `*_v` valid bit (`ifid_v`, `idex_v`, `exmem_v`) that tracks whether the stage contains a real instruction. Bubbles (v=0) propagate through the pipeline and are squashed at side-effect points (register writes are gated by `exmem_reg_w & exmem_v`, memory requests by `exmem_dmem_w & exmem_v`). Valid bits are cleared on reset, on branch mispredict flush (`bp_mispredict`), on taken branch flush when unpredicted (`fit & ~idex_pred_taken`), and when a stall inserts a bubble.

### Stall & Freeze Semantics

When `mem_stall` is asserted (MemCtrl busy), **all** pipeline registers hold their current values — the entire pipeline freezes. The `core.v` always blocks for `ifid_*`, `idex_*`, and `exmem_*` all check `if(mem_stall) ... hold` before any other condition.

Pipeline-specific stalls:
- **`id_stall`** = `ex_stall | id_data_stall` — prevents IF->ID and ID->EX from advancing. When `id_stall` is asserted, `ifid_v` is cleared (bubble inserted at ID stage).
- **`ex_stall`** = `ex_alu_stall | mem_stall` — prevents EX->MEM from advancing. When asserted, `idex_v` is cleared by the next non-stall cycle.
- **`id_data_stall`** (load-use hazard): asserted by `forward.vhd` when an EX-stage LW targets ID-stage rs/rt.

### Branch Prediction (Lab4: Dynamic BHT)

A 16-entry direct-mapped Branch History Table (BHT) with 2-bit saturating counters predicts branch direction and target at the IF stage. Prediction travels through the pipeline alongside the instruction.

**BHT structure** (`branch_predictor.v`):
- 16 entries, direct-mapped (index = `PC[5:2]`, tag = `PC[31:6]`)
- 2-bit saturating counter per entry: 00=StrongNT, 01=WeakNT, 10=WeakT, 11=StrongT
- Predicted taken when counter MSB is 1 (WeakT or StrongT)
- Stores 32-bit branch target per entry
- On tag mismatch (different branch at same index): if existing counter is 00 (StrongNT), replace; otherwise decrement the existing counter (decay)

**Prediction pipeline**: Prediction flows through `ifid_pred_taken/target` -> `idex_pred_taken/target`. At EX stage, prediction is compared against actual branch resolution.

**PC logic priority** (in `core.v` always block):
1. Reset -> `0x8000_0000`
2. `bp_mispredict & ~mem_stall` -> actual taken target (`fit_target`) or sequential past delay slot (`idex_pc + 8`)
3. `fit & ~mem_stall & ~idex_pred_taken` -> actual branch target (taken branch that wasn't predicted)
4. `pred_delayed_branch` -> `pred_delayed_target` (predicted target, after delay slot executed)
5. Default: if BHT predicts taken, set `pred_delayed_branch` flag and fetch `pc + 4` (the delay slot) next

**Mispredict detection** (`core.v:394-396`):
```verilog
bp_mispredict = idex_is_branch & idex_v &
    ((idex_pred_taken != ex_actual_taken) |
     (idex_pred_taken & ex_actual_taken & (idex_pred_target != fit_target)));
```
A branch mispredicts when: direction is wrong, OR predicted taken but target address is wrong (JR/JALR with changing register).

**Mispredict recovery**: On `bp_mispredict`, IF/ID is flushed (`ifid_v=0`), ID stage is NOT cleared (the delay slot must execute), and PC redirects to the correct path. The BHT is updated in the same cycle with actual outcome.

**BHT update policy**: Updated every cycle when a branch is in EX (`idex_is_branch & idex_v & ~mem_stall`). Hit or empty entry: increment/decrement saturating counter. Tag mismatch: only replace if existing counter is 00 (StrongNT), otherwise decay the existing entry.

### Forwarding (`forward.vhd`)

A purely combinational block that does three things:

1. **Forward from EX stage**: If `ex_v & ex_reg_w & (ex_rd == id_rs)` and `ex_datatoreg == 0` (i.e., EX is NOT LW), forward `ex_alu_out`. LW in EX is NOT forwarded (data not ready yet) — this triggers a stall instead.

2. **Forward from MEM stage**: If MEM has a valid write to the matching register, forward `dmem_rdata` (for LW) or `mem_alu_out` (for ALU results). Lower priority than EX — checked via `if/elsif` chain.

3. **Load-use hazard detection**: If `ex_v & ex_datatoreg & (ex_rd != 0)` and that register matches `id_rs` or `id_rt`, assert `id_data_stall`. This stalls the pipeline for one cycle to allow the LW to reach MEM where data is available.

### Data Flow

- **Register file** (`regfile.v`): Combinational read via `regs_next` generate loop (write-bypass: if `rd == rs` and `reg_wen`, `rs_val` gets `data` directly). Write on next posedge.
- **ALU operands**: `alu_a_val` selects between `idex_rs_val` (A_RS), `idex_pc` (A_PC), or `idex_imm` (A_SA). `alu_b_val` selects between `idex_rt_val` (B_RT), `idex_imm` (B_SI), or `8` (B_8).
- **Byte-enable** (`core.v:322-326`): For SB/LB (`dmem_use_be=1`), `be` is derived from `ex_addr[1:0]` — one-hot low-active encoding (e.g., address[1:0]=00 -> be=1110 enables byte 3). For SW/LW, `be=0000`.
- **SB write data replication**: `ex_wdata = {4{idex_rt_val[7:0]}}` for SB — the byte is replicated to all 4 byte lanes, and `be` selects which lane is written.
- **LB sign-extension**: `dmem_rdata_be` extracts and sign-extends the correct byte from the 32-bit memory read based on `be`.

### Memory Map (from MemCtrl)

- **BaseRAM**: `req_addr[22] == 0` — default, 20-bit address bus -> `addr[21:2]`
- **ExtRAM**: `req_addr[22] == 1` — window at `0x8040_0000`
- **UART**: `req_addr[31:4] == 28'hbfd003f` — serial port, 8 wait cycles
- **Instruction fetch starts at**: `0x8000_0000` (reset PC in `core.v:103`)
- **MemCtrl arbitration**: Data access (`data_req`) has priority over instruction fetch when both request simultaneously (`pick_data = data_req` in S_IDLE).
- **MemCtrl timing**: SRAM access = 3 cycles (READ/WRITE 1 cycle + WAIT 2 cycles). `mem_stall = (state != IDLE)`.
- Write buffer required by Lab2 spec but **not yet implemented** — SW still blocks CPU for 3 cycles.

### iCache (`iCache.v`)

4-way set-associative, 4 sets, 4 words/block = 256 bytes total capacity (64 instructions).

- **Address mapping**: tag = `pc[31:6]`, index = `pc[5:4]`, word = `pc[3:2]`
- **Replacement**: Round-robin counter per set (`repl_ctr`), incremented on miss allocation.
- **Hit detection**: Combinational — 4-way parallel tag compare against valid bits. On miss, `core_stall` asserts combinatorially so Core never latches invalid `core_inst` (which is forced to 0 on miss).
- **Miss fill** (`S_MISS_FILL` state): Fills all 4 words of the block in sequence. Tracks ownership of `mem_stall` transactions by detecting `stall_rise` and checking `data_req` — if `data_req` is low when mem_stall rises, the transaction belongs to iCache. Each fill cycle: wait for mem_stall fall -> latch data -> advance `fill_cnt` -> when `fill_cnt == 3`, set valid+tag and return to IDLE.

### Multiplier (ALU `mult_gen_0` IP)

MUL (ALU type `4'd12`) is the only multi-cycle ALU operation. State machine:

1. **IDLE -> LOAD_IP**: On `valid & alu_type=MUL`, convert both operands to absolute values (for signed multiplication on unsigned IP), compute sign = `a[31] xor b[31]`.
2. **LOAD_IP -> MULTIPLYING**: Wait one cycle for IP to sample inputs.
3. **MULTIPLYING -> WRITEBACK**: Latch `mult_p[31:0]`, restore sign.
4. **WRITEBACK -> IDLE**: Hold result stable for one EX stage cycle.

`alu_stall` is asserted during IDLE(when MUL detected), LOAD_IP, and MULTIPLYING — 3 stall cycles total per multiply.

### Instruction Set (from `Decode.vhd`)

| Category | Instructions |
|----------|-------------|
| R-type (opcode=0) | ADD, ADDU, SUB, SUBU, AND, OR, XOR, SLT, SLTU, SLL, SRL, SRA, SLLV, SRLV, SRAV, JR, JALR, MUL |
| SPECIAL2 (opcode=011100) | MUL (funct=000010) |
| I-type arithmetic | ADDI, ADDIU, ANDI, ORI, XORI, LUI, SLTI, SLTIU |
| Memory | LW, SW, LB, SB |
| Branch (REGIMM) | BEQ, BNE, BGEZ, BGTZ, BLEZ, BLTZ |
| Jump | J, JAL |

All immediates are sign-extended except LUI (upper half), ANDI/ORI/XORI (zero-extended).

### Mixed-Language Notes

- **VHDL modules**: `Decode.vhd`, `alu.vhd`, `forward.vhd`
- **Verilog modules**: `core.v`, `regfile.v`, `iCache.v`, `branch_predictor.v`, `MemCtrl.v`, `thinpad_top.v` / `dpad_top.v`
- `headder.vh` is Verilog-only (` `define` macros). VHDL modules hardcode the same constants (e.g., `alu_type = "1100"` for MUL in alu.vhd, `br_type` cases use 4-bit literals).

### Global Defines (`headder.vh`)

ALU types (4-bit): `ADD=0, SUB=1, SLT=2, SLTU=3, AND=4, OR=5, XOR=6, LUI=7, SLL=8, SRL=9, SRA=10, RS2=11, MUL=12, LINK=15`

Branch types (4-bit): `BEQ=0, BNE=1, BGEZ=2, BGTZ=3, BLEZ=4, BLTZ=5, J=6, JAL=7, JR=8, JALR=9, NOP=10`

Operand select: `A_RS=0, A_PC=1, A_SA=2`, `B_RT=0, B_SI=1, B_8=2`

Cache params: `ICACHE_SETS=4, ICACHE_WAYS=4, ICACHE_BLOCK_WORDS=4`

BHT params: `BHT_ENTRIES=16, BHT_INDEX_BITS=4` (PC[5:2] index)

### Coding Conventions

- **`~|` is an equality comparator**: `core.v` uses `~|(x ^ y)` to test `x == y` as a 1-bit result. `~|` is NOR reduction: XOR the bits, then NOR them all — returns 1 only when every bit matches. Equivalent to `(x == y)` but used throughout the project as a consistent style choice.
- **`headder.vh` macros vs VHDL literals**: ALU/branch type constants are `define`d for Verilog but hardcoded in VHDL (`alu_type <= "1100"` for MUL). Changing a type encoding requires updating both `headder.vh` AND the VHDL source files.

### Known Quirks

- **Mispredict flush leaves ID stage alive** (`core.v:287-291`): When `bp_mispredict` fires, `idex_v` is NOT cleared — only the prediction metadata is zeroed. This is correct: the delay-slot instruction is in ID and must execute. IF/ID is flushed (`ifid_v=0`) to discard the wrongly-fetched target instruction.
- **`exmem_v` branch kill** (`core.v:421-422`): The condition `if(fit && ~idex_reg_w)` kills a taken branch in MEM only if it does NOT write a register. JAL/JALR (`idex_reg_w=1`) must reach WB to write the return address; pure branches (BEQ, J, JR, etc.) are squashed in MEM to avoid unnecessary memory stalls.

## Lab Progression

| Lab | What's Built | Status |
|-----|-------------|--------|
| Lab1 | Decode, ALU, Forward (basic 5-stage pipeline) | Done |
| Lab2 | MemCtrl with multi-cycle SRAM access + write buffer | Done |
| Lab3 | Instruction Cache (iCache) | Done |
| Lab4 | Branch prediction (16-entry BHT with 2-bit saturating counter) | Done |

The `learn/` directory contains the code at Lab3 completion state. Each lab builds incrementally on the previous one.

## Known Bugs & Optimization Points

### Fixed
- **iCache block fill second word corruption** (Fix 1): Address advance logic was one cycle late, causing word 1 of every cache block to be a duplicate of word 0.
- **MUL re-trigger during mem_stall** (Fix 2): ALU MUL state machine would restart when mem_stall released, doubling multiply latency.
- **Branch delay slot re-fetch** (Fix 3): `fit` signal incorrectly flushed the delay slot instruction from `idex`, wasting 2 cycles per taken branch. Fully obsoleted by Lab4 predictor (the `delayed_branch` register no longer exists).

### Unfixed (low priority)
- **MemCtrl.v**: Write buffer not implemented (Lab2 spec requirement); UART returns constant 0.
- **alu.vhd**: Multiplier FSM assumes IP core latency is exactly 2 cycles — verify `mult_gen_0` pipeline config in Vivado.
- **alu.vhd**: J/JAL target address uses `pc+4` high bits instead of `pc` high bits (only fails at 256MB boundary, not triggered in lab).
- **alu.vhd**: `rs_v` port declared but unused; sensitivity list missing `mult_result`.
- **Decode.vhd**: SLL/SRL/SRA `use_rt` implicitly depends on R-type outer default — would break silently if outer default changes.
- **forward.vhd**: RT forwarding block missing explicit `else null;` (asymmetric with RS block).
