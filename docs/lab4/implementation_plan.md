# Lab4 分支预测 实现方案

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a 2-bit saturating-counter dynamic branch predictor (BHT) to the IF stage, with mispredict detection and pipeline flush in EX stage.

**Architecture:** New `branch_predictor.v` module instantiated inside `core.v`. BHT has 16 direct-mapped entries (PC[5:2] index), 2-bit saturating counters, and a 32-bit target address per entry. The predictor influences next-PC selection in IF stage; EX stage verifies prediction and triggers mispredict flush. Fix 3 (delay slot re-fetch) is included as a prerequisite since it touches the same PC logic.

**Tech Stack:** Verilog, Vivado 2019, Xilinx xc7k70tfbv676-1

---

## File Structure

| File | Action | Purpose |
|------|--------|---------|
| `headder.vh` | Modify | Add BHT parameter macros |
| `branch_predictor.v` | **Create** | BHT module (2-bit saturating counter, 16-entry direct-mapped) |
| `core.v` | Modify | Integrate predictor into IF stage PC logic, carry prediction through pipeline, mispredict detection in EX |
| `thinpad_top.v` | No change | Predictor is internal to Core |

---

## Design Decisions

### BHT Parameters
- **16 entries**, direct-mapped (no associativity)
- Index: `PC[5:2]` (4 bits), Tag: `PC[31:6]` (26 bits)
- 2-bit saturating counter per entry: 00=Strong Not, 01=Weak Not, 10=Weak Taken, 11=Strong Taken
- 32-bit target address per entry (records last taken target for this branch)
- Valid bit per entry
- **Allocate-on-taken**: Only allocate/update BHT entries when a branch is actually taken in EX. Non-taken branches decrement the counter but don't allocate.

### Prediction Flow
```
IF: BHT[pc] → if hit && counter[1]==1 → predict taken, next PC = BHT target (after delay slot)
    Prediction info (taken + target) registered into ifid_pred_*
ID: ifid_pred_* → idex_pred_*
EX: idex_pred_taken vs actual jump → mispredict? → flush IF/ID, redirect PC
    Update BHT with actual outcome
```

### Interaction with Delay Slot
The delay slot instruction always executes. Prediction only affects the instruction AFTER the delay slot:
- Branch at PC=X, delay slot at X+4
- Without prediction: after fetching X+4, PC → X+8 (sequential)
- With prediction: after fetching X+4, PC → predicted_target (speculative)

### Mispredict Recovery
- **Predicted taken, actually not taken**: Flush IF/ID, PC → `ex_pc + 8` (sequential past delay slot)
- **Predicted not taken, actually taken**: Flush IF/ID, PC → actual target (`fit_target`)
- **Predicted target wrong** (JR/JALR): Flush IF/ID, PC → actual target

---

### Task 1: Update `headder.vh` — add BHT parameter macros

**Files:**
- Modify: `learn/headder.vh` (append after iCache params at line 70)

- [ ] **Step 1: Add BHT macros**

Append after line 70 (` `define ICACHE_BLOCK_WORDS 4`):

```verilog
// BHT parameters (Lab4)
`define BHT_ENTRIES    16   // 16 entries direct-mapped
`define BHT_INDEX_BITS 4    // PC[5:2]
```

Full change at `headder.vh:70`:

```verilog
`define ICACHE_BLOCK_WORDS 4    // 每块4条指令（16字节）

// BHT parameters (Lab4)
`define BHT_ENTRIES    16   // 16 entries direct-mapped
`define BHT_INDEX_BITS 4    // PC[5:2]
```

- [ ] **Step 2: Commit**

---

### Task 2: Create `branch_predictor.v` — BHT module

**Files:**
- Create: `learn/branch_predictor.v`

- [ ] **Step 1: Write the module**

```verilog
`timescale 1ns / 1ps
`include "headder.vh"

module branch_predictor #(
    parameter ENTRIES = `BHT_ENTRIES,
    parameter INDEX_W = `BHT_INDEX_BITS
)(
    input  wire        clk,
    input  wire        rst,

    // ---- IF stage lookup (combinational) ----
    input  wire [31:0] lookup_pc,
    output wire        pred_taken,
    output wire [31:0] pred_target,

    // ---- EX stage update (sequential) ----
    input  wire        update_valid,
    input  wire [31:0] update_pc,
    input  wire        update_taken,
    input  wire [31:0] update_target
);

    localparam TAG_W = 32 - INDEX_W - 2;  // 26 bits for INDEX_W=4

    // BHT storage
    reg             valid   [0:ENTRIES-1];
    reg [TAG_W-1:0] tag     [0:ENTRIES-1];
    reg [1:0]       counter [0:ENTRIES-1];  // 2-bit saturating
    reg [31:0]      target  [0:ENTRIES-1];

    // ---- Address decode (combinational) ----
    wire [INDEX_W-1:0] lookup_index = lookup_pc[INDEX_W+1:2];
    wire [TAG_W-1:0]   lookup_tag   = lookup_pc[31:INDEX_W+2];

    wire [INDEX_W-1:0] update_index = update_pc[INDEX_W+1:2];
    wire [TAG_W-1:0]   update_tag   = update_pc[31:INDEX_W+2];

    // ---- Hit detection (combinational) ----
    wire hit = valid[lookup_index] && (tag[lookup_index] == lookup_tag);
    assign pred_taken  = hit && counter[lookup_index][1];  // MSB: 1=taken
    assign pred_target = target[lookup_index];

    // ---- BHT update (sequential) ----
    integer i;
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < ENTRIES; i = i + 1) begin
                valid[i]   <= 1'b0;
                tag[i]     <= {TAG_W{1'b0}};
                counter[i] <= 2'b01;  // weak not-taken
                target[i]  <= 32'b0;
            end
        end else if (update_valid) begin
            if (hit || ~valid[update_index]) begin
                // Hit or empty entry: update in place
                valid[update_index] <= 1'b1;
                tag[update_index]   <= update_tag;

                if (update_taken) begin
                    // Saturating increment
                    counter[update_index] <= (counter[update_index] == 2'b11)
                        ? 2'b11 : (counter[update_index] + 2'd1);
                    target[update_index] <= update_target;
                end else begin
                    // Saturating decrement
                    counter[update_index] <= (counter[update_index] == 2'b00)
                        ? 2'b00 : (counter[update_index] - 2'd1);
                end
            end else begin
                // Tag mismatch (different branch mapped to same index):
                // replace entry if previous branch is now consistently not-taken
                if (counter[update_index] == 2'b00) begin
                    valid[update_index] <= 1'b1;
                    tag[update_index]   <= update_tag;

                    if (update_taken) begin
                        counter[update_index] <= 2'b10;  // weak taken
                        target[update_index]  <= update_target;
                    end else begin
                        counter[update_index] <= 2'b01;  // weak not-taken
                    end
                end else begin
                    // Existing entry still active: decrement it (decay)
                    counter[update_index] <= counter[update_index] - 2'd1;
                end
            end
        end
    end

endmodule
```

- [ ] **Step 2: Commit**

---

### Task 3: Modify `core.v` — Fix 3 (delay slot) + integrate branch predictor

**Files:**
- Modify: `learn/core.v`

This is the largest task. Changes fall into 5 areas:

#### Area A: New signal declarations (add after line 31 `wire if_stall;`)

- [ ] **Step 1: Add prediction and mispredict signals**

After line 31 (`wire if_stall;`), add:

```verilog
    // Branch predictor signals (Lab4)
    wire bp_taken;
    wire [31:0] bp_target;
    wire bp_mispredict;
    reg  [31:0] ex_pc;              // PC of instruction in EX stage (for mispredict recovery)
    reg         ifid_pred_taken;    // prediction for instruction in ID stage
    reg [31:0]  ifid_pred_target;
    reg         idex_pred_taken;    // prediction for instruction in EX stage
    reg [31:0]  idex_pred_target;

    // Branch predictor update signals
    wire bp_update_valid;
    wire bp_update_taken;
```

- [ ] **Step 2: Commit**

#### Area B: Branch predictor instantiation (add near other module instances, around line 185)

- [ ] **Step 3: Instantiate branch_predictor**

After the `Decode dec(...)` instance (line 185), add:

```verilog
    branch_predictor #(
        .ENTRIES(`BHT_ENTRIES),
        .INDEX_W(`BHT_INDEX_BITS)
    ) bp (
        .clk(clk),
        .rst(rst),
        .lookup_pc(pc),
        .pred_taken(bp_taken),
        .pred_target(bp_target),
        .update_valid(bp_update_valid),
        .update_pc(idex_pc),
        .update_taken(bp_update_taken),
        .update_target(fit_target)
    );
```

- [ ] **Step 4: Commit**

#### Area C: PC logic — Fix 3 + prediction (replace lines 105-129)

- [ ] **Step 5: Rewrite PC always block**

Replace the `delayed_branch` declaration (lines 105-106) and PC always block (lines 108-129) with:

```verilog
    reg delayed_branch;        // actual taken-branch redirect pending
    reg [31:0] delayed_target; // actual branch target address

    // ---- PC control with branch prediction ----
    always @(posedge clk) begin
        if(rst) begin
            pc <= 32'h8000_0000;
            delayed_branch <= 1'b0;
            delayed_target <= 32'h0;
        end
        // Priority 1: Mispredict flush
        else if(bp_mispredict & (~mem_stall)) begin
            // Redirect to correct path
            if(idex_pred_taken)
                pc <= ex_pc + 32'd8;        // pred taken, actual not: go sequential past delay slot
            else
                pc <= fit_target;            // pred not taken, actual taken: go to target
            delayed_branch <= 1'b0;
        end
        // Priority 2: Branch actually taken in EX (fit), but only if not already predicted taken
        else if(fit & (~mem_stall) & ~idex_pred_taken) begin
            // Unpredicted taken branch: redirect to delay slot, then target
            pc <= fit_pc;
            delayed_branch <= 1'b1;
            delayed_target <= fit_target;
        end
        // Priority 3: Normal PC advance
        else if((~if_stall) & (~mem_stall)) begin
            if(delayed_branch) begin
                pc <= delayed_target;
                delayed_branch <= 1'b0;
                delayed_target <= 32'b0;
            end
            else begin
                // Look up BHT for the instruction we are about to fetch (current pc)
                // If BHT predicts taken, redirect to predicted target AFTER the delay slot
                if(bp_taken) begin
                    delayed_branch <= 1'b1;
                    delayed_target <= bp_target;
                end
                pc <= pc + 32'h4;
            end
        end
    end
```

- [ ] **Step 6: Commit**

#### Area D: Fix 3 — don't flush `idex_v` on `fit` (line 237-238), add prediction pipeline registers (lines 230-248)

- [ ] **Step 7: Fix idex_v (Fix 3) and add prediction pipeline**

Replace the `idex_v` always block (lines 230-248):

```verilog
    // ---- idex_v with prediction pipeline ----
    always @(posedge clk) begin
        if(rst) begin
            idex_v         <= 1'b0;
            idex_pred_taken  <= 1'b0;
            idex_pred_target <= 32'b0;
        end
        else if(mem_stall) begin
            idex_v         <= idex_v;
            idex_pred_taken  <= idex_pred_taken;
            idex_pred_target <= idex_pred_target;
        end
        else if(bp_mispredict) begin
            // Mispredict: flush the instruction in ID (wrong-path after delay slot)
            // But keep idex_v if it holds the delay slot (delay slot must execute)
            // The delay slot is NOT flushed — only the wrong-path instruction after it
            idex_v         <= 1'b0;
            idex_pred_taken  <= 1'b0;
            idex_pred_target <= 32'b0;
        end
        // Fix 3: fit no longer clears idex_v (delay slot must flow through)
        else if(~ex_stall) begin
            if(id_stall) begin
                idex_v         <= 1'b0;
                idex_pred_taken  <= 1'b0;
                idex_pred_target <= 32'b0;
            end
            else begin
                idex_v         <= ifid_v;
                idex_pred_taken  <= ifid_pred_taken;
                idex_pred_target <= ifid_pred_target;
            end
        end
    end
```

- [ ] **Step 8: Commit**

#### Area E: ifid prediction registers + fit flush logic (modify lines 131-165)

- [ ] **Step 9: Add ifid_pred registers and modify fit/bp_mispredict flush**

Replace the `ifid_v` always block (lines 131-147) and `ifid_pc/ifid_inst` always block (lines 149-165) with:

```verilog
    assign if_stall <= id_stall;

    // ---- ifid valid + prediction ----
    always @(posedge clk) begin
        if(rst) begin
            ifid_v          <= 1'b0;
            ifid_pred_taken   <= 1'b0;
            ifid_pred_target  <= 32'b0;
        end
        else if(mem_stall) begin
            ifid_v          <= ifid_v;
            ifid_pred_taken   <= ifid_pred_taken;
            ifid_pred_target  <= ifid_pred_target;
        end
        else if(fit | bp_mispredict) begin
            // Flush IF/ID on actual taken branch OR mispredict
            ifid_v          <= 1'b0;
            ifid_pred_taken   <= 1'b0;
            ifid_pred_target  <= 32'b0;
        end
        else begin
            if(~id_stall) begin
                ifid_v          <= ~if_stall;
                // Capture prediction for the instruction just fetched
                ifid_pred_taken   <= bp_taken;
                ifid_pred_target  <= bp_target;
            end
        end
    end

    always @(posedge clk) begin
        if(rst) begin
            ifid_pc   <= 32'h0;
            ifid_inst <= 32'h0;
        end
        else if(mem_stall) begin
            ifid_pc   <= ifid_pc;
            ifid_inst <= ifid_inst;
        end
        else begin
            if(~id_stall) begin
                ifid_pc   <= pc;
                ifid_inst <= inst;
            end
        end
    end
```

- [ ] **Step 10: Commit**

#### Area F: ex_pc tracking + bp_mispredict detection + BHT update (after line 333, near ALU instance)

- [ ] **Step 11: Add ex_pc register, mispredict logic, BHT update signals**

After line 333 (the ALU instance), add:

```verilog
    // ---- EX stage PC tracking (for mispredict recovery) ----
    always @(posedge clk) begin
        if(rst) begin
            ex_pc <= 32'b0;
        end
        else if(~ex_stall & ~mem_stall) begin
            ex_pc <= idex_pc;
        end
    end

    // ---- Mispredict detection ----
    // idex_pred_taken was set when this branch was in IF stage
    // jump comes from ALU (actual branch outcome in EX)
    // idex_is_branch from Decode tells us if this is actually a branch instruction
    wire ex_actual_taken;
    assign ex_actual_taken = jump & idex_v;
    assign bp_mispredict = idex_is_branch & idex_v &
        (idex_pred_taken != ex_actual_taken);

    // ---- BHT update ----
    // Allocate/update when a branch instruction resolves in EX
    assign bp_update_valid = idex_is_branch & idex_v & ~mem_stall;
    assign bp_update_taken = jump;  // actual taken/not-taken from ALU
```

- [ ] **Step 12: Commit**

#### Area G: Fix 3 — exmem_v (fix the dead code at lines 348-365)

- [ ] **Step 13: Fix exmem_v always block to not clear delay slot**

Replace the `exmem_v` always block (lines 348-365):

```verilog
    // ---- exmem_v (Fix 3: don't clear delay slot on fit) ----
    always @(posedge clk)begin
        if(rst)begin
            exmem_v <= 1'b0;
        end
        else if(mem_stall)begin
            exmem_v <= exmem_v;
        end
        else if(~mem_stall)begin
            // Fix 3: removed the `if(fit) exmem_v <= 0` dead code.
            // The delay slot (in idex when fit=1) must flow into MEM.
            if(ex_stall)begin
                exmem_v <= 1'b0;
            end else begin
                exmem_v <= idex_v;
            end
        end
    end
```

- [ ] **Step 14: Commit**

---

### Task 4: Add `exmem_be` reset width fix (known bug)

**Files:**
- Modify: `learn/core.v` line 377

- [ ] **Step 1: Fix exmem_be reset from 3'b0 to 4'b0**

At line 377, change:
```verilog
            exmem_be <= 3'b0;
```
to:
```verilog
            exmem_be <= 4'b0;
```

- [ ] **Step 2: Commit**

---

### Task 5: ALU MUL re-trigger fix (Fix 2 from optimization.md)

**Files:**
- Modify: `learn/alu.vhd`

This is a correctness prerequisite: during `mem_stall`, the MUL state machine re-triggers because it doesn't check `ex_stall`.

- [ ] **Step 1: Add stall gate to MUL state machine**

In `alu.vhd`, modify the IDLE state transition (line 78):

Change:
```vhdl
if valid = '1' and alu_type = "1100" then
```

To:
```vhdl
if valid = '1' and alu_type = "1100" and ex_stall = '0' then
```

- [ ] **Step 2: Commit**

---

### Task 6: iCache address advance fix (Fix 1 from optimization.md)

**Files:**
- Modify: `learn/iCache.v`

- [ ] **Step 1: Move address advance to stall_fall, remove stall_cycle hack**

Remove the `stall_cycle == 3'd2` early-advance block (lines 163-167 in iCache.v) and instead advance address inside the `stall_fall` branch.

Replace the S_MISS_FILL case (approximately lines 150-183):

```verilog
                S_MISS_FILL: begin
                    // Detect ownership of each mem_stall burst
                    if (stall_rise) begin
                        is_our_txn <= !data_req;
                    end

                    // mem_stall falling edge: our transaction just completed, data valid
                    if (stall_fall && is_our_txn) begin
                        data[repl_way][miss_index][fill_cnt] <= mem_inst_data;

                        if (fill_cnt == BLOCK_WORDS - 1) begin
                            valid[repl_way][miss_index] <= 1'b1;
                            tag[repl_way][miss_index]   <= miss_tag;
                            state       <= S_IDLE;
                            mem_inst_req <= 1'b0;
                        end else begin
                            fill_cnt <= fill_cnt + 2'd1;
                            // Advance address for next word (replaces stall_cycle hack)
                            mem_inst_addr <= mem_inst_addr + 32'd4;
                        end
                    end
                end
```

Also remove the `stall_cycle` register declaration and all references to it (since `stall_cycle` is no longer used).

- [ ] **Step 2: Commit**

---

### Task 7: Simulation verification

**Files:**
- Test files: `LAB/labf.bin`, `LAB/testfile.bin`

- [ ] **Step 1: Run behavioral simulation with labf.bin**

Setup:
1. Open Vivado project
2. Set `BASE_RAM_INIT_FILE` to `labf.bin` path in `tb.sv`
3. Run Behavioral Simulation
4. Add `tb/dut/core/ref/regs` to wave window
5. Verify regs values match Lab1/Lab2/Lab3 expected values (see `docs/lab1/requirements.md`)

- [ ] **Step 2: Observe branch prediction behavior in waveforms**

Add these signals to the wave window for verification:
- `tb/dut/core/pc_o` — PC progression (should show target jumps without bubbles on correct predictions)
- `tb/dut/core/bp_taken` — BHT prediction output
- `tb/dut/core/bp_mispredict` — should pulse on first few iterations, then stay low
- `tb/dut/core/ifid_pred_taken` — prediction flowing through pipeline
- `tb/dut/core/idex_pred_taken` — prediction at EX stage
- `tb/dut/core/jump` — actual branch outcome from ALU

Expected behavior with labf.bin:
- First loop iteration: cold BHT misses, no predictions, normal fit/delayed_branch flow
- Subsequent iterations: BHT hits on loop branches, `bp_taken=1`, PC jumps directly to target after delay slot
- `bp_mispredict` should not pulse for stable loop branches after training

- [ ] **Step 3: Repeat with testfile.bin**

Same verification steps, confirm regs match expected values.

- [ ] **Step 4: Screenshot for report**

Capture:
1. Cold start / first loop: show BHT misses and fit-based PC redirect
2. Trained predictor: show `bp_taken=1` ahead of branch, PC advancing without bubbles
3. Mispredict recovery (if observable): show `bp_mispredict=1`, PC redirect to correct path

- [ ] **Step 5: Commit any simulation config files**

---

## Verification Checklist

Before submission:
- [ ] `labf.bin` regs[31:0] all match expected values
- [ ] `testfile.bin` regs[31:0] all match expected values
- [ ] Branch predictor reduces fit-based pipeline bubbles in labf's main loop
- [ ] Mispredict recovery correctly flushes wrong-path instructions (regs unchanged)
- [ ] Delay slot instructions always execute (no branch-related correctness bugs)
- [ ] iCache still works (Cache hit in loops, cold miss on first access)
- [ ] MUL instructions still produce correct results (Fix 2 didn't break multiplier)
- [ ] Vivado synthesis completes without critical warnings
