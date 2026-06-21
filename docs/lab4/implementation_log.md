# LAB4 实现记录

## 时间

2026年5月29日

## 实现文件（LAB/little mips.srcs/sources_1/new/）

### 新增文件
- `branch_predictor.v`（97行）— BHT模块，16项直接映射，2位饱和计数器

### 修改文件
- `headder.vh`（+4行）— BHT_ENTRIES=16, BHT_INDEX_BITS=4
- `core.v`（+~60行，改5处）— PC预测逻辑、预测流水线寄存器、mispredict检测、BHT更新

### 不动文件
- `MemCtrl.v`, `Decode.vhd`, `forward.vhd`, `regfile.v`, `thinpad_top.v` — 均不改
- `alu.vhd` — Fix 2 (mem_stall freeze) 已在Lab3阶段修复
- `iCache.v` — Fix 1 (stall_cycle移除) 已在Lab3阶段修复

## 架构变化

```
Lab3:  Core ──→ iCache ──→ MemCtrl ──→ SRAM
       fit→pc直接跳转目标（延迟槽已在ID/EX中）

Lab4:  Core (含BHT) ──→ iCache ──→ MemCtrl ──→ SRAM
       IF阶段查BHT，预测跳转则提前将pc重定向到目标
       pred_delayed_branch机制比fit早1周期生效
```

### BHT 设计参数

| 参数 | 值 | 含义 |
|------|-----|------|
| ENTRIES | 16 | 直接映射 |
| INDEX | PC[5:2]（4位） | 16个槽位 |
| TAG | PC[31:6]（26位） | 地址匹配 |
| Counter | 2位饱和计数器 | 00=强不跳, 01=弱不跳, 10=弱跳, 11=强跳 |
| Target | 32位 | 上次跳转目标地址 |
| 替换策略 | 直接映射 + decay | Tag不匹配时：counter=00则替换，否则递减现有counter |

### PC 控制优先级

1. **bp_mispredict & ~mem_stall**：预测失败
   - pred taken, actual not → pc = ex_pc + 8（顺序路径，跳过延迟槽）
   - pred not taken, actual taken → pc = fit_target（跳转目标）
   - 清除 pred_delayed_branch
2. **fit & ~mem_stall & ~idex_pred_taken**：未预测的跳转，直接跳到目标
3. **~if_stall & ~mem_stall**：正常推进
   - pred_delayed_branch=1 → pc = pred_delayed_target（预测目标）
   - pred_delayed_branch=0 → 查BHT，若预测跳转则设pred_delayed_branch；pc+=4

### 预测流水线

```
IF: BHT[pc] → bp_taken, bp_target
    锁存到 ifid_pred_taken, ifid_pred_target
ID: ifid_pred_* → idex_pred_*
EX: idex_pred_taken vs ex_actual_taken (= jump & idex_v)
    不一致 → bp_mispredict=1
    一致 → 正常流水，更新BHT
```

### mispredict 冲刷

- `ifid_v`：清零（flush IF/ID中的错误路径指令）
- `idex_v`：**不清零**（idex中是延迟槽，必须执行）
- `idex_pred_*`：清零（清除错误预测标记）
- `pred_delayed_branch`：清零（取消预测重定向）

### 与 LAB 已有优化的协调

LAB core.v 已在 Lab3 阶段应用了 Fix 3：
- PC 逻辑无 delayed_branch 机制：`fit` 直接 `pc <= fit_target`
- `fit` 不清 `idex_v`（延迟槽流入 EX）
- `exmem_v` 在 `fit && ~idex_reg_w` 时清除纯分支指令（JAL/JALR保留以写回返回地址）

Lab4 的 `pred_delayed_branch` 是新增的预测专用机制，与 fit 路径互斥（fit 仅在 `~idex_pred_taken` 时触发）。

## 验证步骤（待执行，需 Vivado）

1. 打开 Vivado 项目，添加 `branch_predictor.v` 到 Design Sources
2. 用 `labf.bin` 和 `testfile.bin` 仿真
3. 验证 regs 值与 Lab1/Lab2/Lab3 一致
4. 观察关键信号：
   - `tb/dut/Core/bp_taken` — BHT预测输出
   - `tb/dut/Core/bp_mispredict` — 预测失败脉冲
   - `tb/dut/Core/pc_o` — PC推进（预测命中时无气泡）
   - `tb/dut/Core/pred_delayed_branch` — 预测重定向标志
   - `tb/dut/Core/ifid_pred_taken` — 预测信息流水线传递
5. 截图：
   - 冷启动/首次循环：BHT未训练，fit路径处理跳转
   - 循环后续迭代：BHT命中，pred_delayed_branch提前重定向PC

## 验证前检查清单

- [ ] `branch_predictor.v` 已加入 Vivado Design Sources
- [ ] `headder.vh` 更新已生效（BHT_ENTRIES, BHT_INDEX_BITS 定义）
- [ ] 仿真顶层模块是 `tb`（tb.sv），不是 thinpad_top
- [ ] BASE_RAM_INIT_FILE 路径正确
- [ ] labf.bin regs 值匹配预期
- [ ] testfile.bin regs 值匹配预期
- [ ] 循环中 bp_mispredict 脉冲数少于首次循环（BHT训练后稳定）
