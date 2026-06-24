# LAB3 实现记录

## 时间

2026年5月3日（截止日期5月6日）

## 实现文件

### 新增文件
- `LAB/little mips.srcs/sources_1/new/iCache.v`（191行）

### 修改文件
- `LAB/little mips.srcs/sources_1/new/headder.vh`（+4行）
- `LAB/little mips.srcs/sources_1/new/thinpad_top.v`（+25行，改3处连线）

### 不动文件
- `core.v` — 流水线控制器不改
- `MemCtrl.v` — 访存控制器不改
- `alu.vhd`, `Decode.vhd`, `forward.vhd`, `regfile.v` — 均不改

---

## 架构变化

```
Lab2:  Core ──→ MemCtrl ──→ SRAM (每次取指4周期)

Lab3:  Core ──→ iCache ──→ MemCtrl ──→ SRAM
              (命中1周期)  (缺失时填充)
              
       数据路径: Core ──→ MemCtrl ──→ SRAM (不变)
```

---

## iCache 设计参数

| 参数 | 值 | 含义 |
|------|-----|------|
| SETS | 4 | 组数（2位索引 [5:4]） |
| WAYS | 4 | 4路组相联 |
| BLOCK_WORDS | 4 | 每块4条指令（16字节） |
| 总容量 | 64条指令 | 4组×4路×4字 |

### 地址划分（32位PC）

```
[31:6]          [5:4]     [3:2]      [1:0]
  Tag(26位)     Index     Word      忽略
```

### 替换策略：Round-Robin

每个 Set 维护 2 位计数器，指向下一个被替换的 Way。每次 Miss 填充后 +1。

---

## 关键设计决策

### 1. 组合 core_stall（同周期命中）

`core_stall` 是组合逻辑而非寄存器输出：

```verilog
assign core_stall = (state == S_MISS_FILL) || ((state == S_IDLE) && miss_detected);
```

**为什么**：如果 core_stall 是寄存器输出，Cache 缺失检测和 stall 生效之间有 1 个周期的延迟。Core 会在那个周期捕获 `inst=0`（假指令），流水线注入一条 NOP，导致寄存器值与 Lab1/Lab2 不一致。

组合 stall 在 PC 变化的同一周期就生效，Core 在时钟沿之前就看到了 stall=1，不会捕获假指令。

### 2. stall_cycle 提前更新地址（消除死周期）

MemCtrl 处理一次 SRAM 访问的 stall 时序：

```
        READ    WAIT(cnt=2)  WAIT(cnt=1)
         ↓          ↓           ↓
stall:   1          1           1 → 0 (回到IDLE)
cycle:   0          1           2 → 完成
```

在 `stall_cycle=2`（最后一个 stall 周期）时提前更新 `mem_inst_addr` 为下一个字地址。MemCtrl 回到 IDLE 后自动锁存新地址，**无需插入死周期**。

### 3. data_req 监听（防止数据访存干扰）

iCache 通过 `data_req` 输入监听总线：

```verilog
if (stall_rise) begin
    is_our_txn <= !data_req;   // data_req=0 → 是我们的Cache填充请求
end
```

当流水线中有未完成的 LW/SW 时，`data_req=1`。MemCtrl 优先处理数据请求（仲裁规则）。iCache 用 `is_our_txn` 标志跳过数据访存的 stall 周期，不会错误地将数据访存结果写进 Cache。

---

## 实现过程中发现并修复的 Bug

### Bug A：组合 vs 寄存器 stall
- **发现**：逻辑审查时发现 core_stall 作为 reg 会导致 1 周期延迟，Core 在 Cache Miss 的第一拍捕获 inst=0
- **修复**：core_stall 改为 wire 组合赋值，缺失瞬间生效

### Bug B：data_req 劫持 Cache 填充
- **发现**：如果流水线中有未完成的 LW，MemCtrl 在 Cache 填充间隙会处理数据请求，iCache 会将数据访存周期计为填充周期
- **修复**：添加 data_req 端口，用 is_our_txn 标志区分

---

## 时序追踪（验证设计正确性）

### 场景：复位后首次取指

```
PC = 0x80000000, Cache 全空

C0: state=IDLE, cache_hit=0 → core_stall=1（组合，立即生效）
    Core 被冻结，不会捕获 inst=0
    FSM: state ← S_MISS_FILL, mem_inst_req=1, mem_inst_addr=0x80000000

C1: MemCtrl 进入 READ → mem_stall=1
    stall_rise → is_our_txn=1, stall_cycle=0

C2: stall_cycle=1 (WAIT cnt=2)

C3: stall_cycle=2 → mem_inst_addr 更新为 0x80000004（提前更新！）
    MemCtrl: WAIT cnt=1→0 → state←IDLE

C4: stall_fall, is_our_txn=1 → 捕获 data[way][set][0]
    fill_cnt=1, mem_inst_req 保持 1
    MemCtrl 回到 IDLE，锁存新地址 0x80000004 ✓

C5-C8: 重复，填充 word 1 (0x80000004)

C9-C12: 填充 word 2 (0x80000008)

C13-C16: 填充 word 3 (0x8000000C)
    stall_fall → valid=1, tag 写入, state←IDLE

C17: state=IDLE, cache_hit=1 → core_stall=0
     Core 捕获 {pc=0x80000000, inst=cached} ✓
     PC 推进到 0x80000004

C18: state=IDLE, cache_hit=1（同一Block） → core_stall=0
     Core 捕获 {pc=0x80000004, inst=cached} ✓
     1周期/条指令！
```

### 场景：Cache Miss 期间有 LW 请求

```
C0-C4: 填充 word 0，fill_cnt=1
C5: MemCtrl 回到 IDLE，但 data_req=1（LW 在 MEM 阶段等待）
    MemCtrl 优先处理 data_req → mem_stall=1
    stall_rise → is_our_txn=!(1)=0 → 不计数
C6-C8: 数据访存完成，stall_fall, is_our_txn=0 → 不捕获 ← 正确！
C9: MemCtrl 回到 IDLE, data_req=0, icache_inst_req=1
    MemCtrl 开始处理 Cache 填充
    stall_rise → is_our_txn=!(0)=1 → 重新计数
    ...正常继续填充 word 1
```

---

## 验证步骤（需在 Windows/Linux + Vivado 上执行）

### Step 1: 拷贝文件
将整个 `LAB/` 目录拷贝到装有 Vivado 2019 的机器。

### Step 2: Vivado 新建项目
1. 打开 Vivado → Create Project → RTL Project
2. 芯片型号: `xc7k70tfbv676-1`
3. Add Sources: `sources_1/new/` 下全部文件 + `sources_1/ip/` 下 mult_gen_0
4. Add Simulation Sources: `sim_1/new/` 下全部文件

### Step 3: 配置测试文件
打开 `tb.sv`，修改 `BASE_RAM_INIT_FILE` 为 `labf.bin` 的绝对路径。

### Step 4: 运行仿真
Run Behavioral Simulation。

### Step 5: 验证正确性
在 Wave Window 中：
- Scope: `tb/dut/core/ref`
- 右击 `regs` → Add to Wave Window
- 点击 Restart 重新仿真
- 对比 regs[31:0] 值与 `docs/lab1/requirements.md` 中的正确结果表

### Step 6: 观察 Cache 效果（截图用）
观察以下信号：
- `tb/dut/icache_inst/core_stall` — 命中时为 0
- `tb/dut/icache_inst/mem_inst_req` — 命中时为 0
- `tb/dut/memctrl/mem_stall` — 命中时无 MemCtrl 活动
- `tb/dut/core/pc_o` — PC 推进速度

### Step 7: 截图（报告用）
1. **冷缺失**: labf 循环首次执行的波形 — icache_stall=1, mem_inst_req=1, 多周期 MemCtrl 访问
2. **Cache 命中**: 循环后续迭代 — icache_stall=0, mem_inst_req=0, PC 每周期递增

---

## 验证前检查清单

- [ ] iCache.v 已加入 Design Sources（非 Simulation Sources）
- [ ] thinpad_top.v 中 MemCtrl 的 `.inst_req/inst_addr/inst_data` 连接到了 iCache 而非 Core
- [ ] Core 的 `.mem_stall` 连接到了 `total_mem_stall` 而非 `mem_stall`
- [ ] 仿真顶层模块是 `tb`（tb.sv），不是 thinpad_top
- [ ] BASE_RAM_INIT_FILE 路径正确且文件存在
- [ ] claude --resume d74d4680-35d0-4b46-9116-eca5aadc7c1f
