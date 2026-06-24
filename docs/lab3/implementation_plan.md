# LAB3 指令 Cache 实现方案

## 背景

Lab3 要求在 Lab2 多周期访存基础上加入指令 Cache。Lab2 的问题：即使 MEM 阶段改为多周期，IF 阶段每次取指令仍需等 SRAM（3 周期/条指令），多周期访存没有真正提高吞吐率。Cache 让高频取指在命中时只需 1 周期，真正释放性能。

截止日期：2026年5月6日 23:59

---

## 一、Cache 参数设计

### 配置（headder.vh 新增宏定义）

| 参数 | 值 | 含义 |
|------|-----|------|
| `ICACHE_SETS` | 4 | 组数（2位索引） |
| `ICACHE_WAYS` | 4 | 4路组相联 |
| `ICACHE_BLOCK_WORDS` | 4 | 每块 4 条指令（16字节） |

**总容量**: 4组 × 4路 × 4字 × 4字节 = **256 字节 = 64 条指令**（满足 ≥32 要求）

### 地址划分（32位 PC 字节地址）

```
[31:6]           [5:4]      [3:2]        [1:0]
   Tag (26位)      Index     Word       Byte
                  (2位, 0-3) (2位, 0-3)  (忽略，指令对齐)
```

### Cache 存储（寄存器实现）

```verilog
reg        valid   [0:ICACHE_WAYS-1][0:ICACHE_SETS-1];
reg [25:0] tag     [0:ICACHE_WAYS-1][0:ICACHE_SETS-1];
reg [31:0] data    [0:ICACHE_WAYS-1][0:ICACHE_SETS-1][0:ICACHE_BLOCK_WORDS-1];
reg [1:0]  repl_ctr[0:ICACHE_SETS-1];  // round-robin替换计数器
```

---

## 二、命中时序：同周期命中

采用**组合逻辑查找**——PC 输入后，在同一周期内完成：索引提取 → Tag 读取与比较 → 数据选择 → 输出 inst。无需额外等待周期。

```
PC → [提取Index] → 读4路Tag+Valid → 4路并行比较 → 命中?→ 选择对应路的数据
                                                    ↓否
                                                   触发Miss FSM
```

---

## 三、iCache 模块设计

### 端口

```verilog
module iCache #(
    parameter SETS = 4,
    parameter WAYS = 4,
    parameter BLOCK_WORDS = 4
)(
    input  wire        clk,
    input  wire        rst,
    // Core 侧
    input  wire [31:0] core_pc,
    input  wire        core_inst_req,
    output wire [31:0] core_inst,
    output wire        core_stall,       // 命中=0, 缺失=1
    // MemCtrl 侧
    output reg         mem_inst_req,
    output reg  [31:0] mem_inst_addr,
    input  wire [31:0] mem_inst_data,
    input  wire        mem_stall
);
```

### 状态机

```
             core_inst_req && 命中
  IDLE ──────────────────────────────→ IDLE (core_stall=0, 输出cache数据)
    │
    │ core_inst_req && 未命中
    ↓
  MISS_FILL                              
    │ 逐字读取: block_base + 0, +4, +8, +12
    │ 通过 MemCtrl, 每字 ~4周期
    │ 所有字读完 → IDLE
```

### IDLE 态组合逻辑

```verilog
// 提取地址字段
wire [1:0]  id_index = core_pc[5:4];
wire [25:0] id_tag   = core_pc[31:6];
wire [1:0]  id_word  = core_pc[3:2];

// 4路并行比较
wire [3:0] way_hit;
for (w = 0; w < WAYS; w++) begin
    assign way_hit[w] = valid[w][id_index] && (tag[w][id_index] == id_tag);
end

// 命中检测
wire cache_hit = |way_hit;

// 数据选择（优先编码器）
always @(*) begin
    core_inst = 32'b0;
    for (w = 0; w < WAYS; w++)
        if (way_hit[w]) core_inst = data[w][id_index][id_word];
end
```

### MISS_FILL 态时序

```
Cycle 0: 检测miss, core_stall=1, 记录fill_cnt=0, mem_inst_addr=block_base+0
Cycle 1: mem_inst_req=1, MemCtrl进入READ
Cycle 2-4: MemCtrl处理 (mem_stall=1), iCache等待
Cycle 5: mem_stall→0, 数据有效, iCache捕获 → 写cache, fill_cnt++, 
         mem_inst_addr更新为block_base+4, mem_inst_req短暂拉低1周期
Cycle 6: mem_inst_req=1, MemCtrl再次进入READ → ...
...重复直到 fill_cnt==BLOCK_WORDS
最后: core_stall=0, state→IDLE, 输出命中的数据
```

**关键时序约束**: 每读一个字后需插入**1个死周期**让地址稳定。这是因为 Verilog 非阻塞赋值导致地址更新和 MemCtrl 锁存存在竞态。

---

## 四、需要修改的文件

### 1. NEW: `iCache.v`
路径: `LAB/little mips.srcs/sources_1/new/iCache.v`
内容: 完整的指令 Cache 模块（见上文设计）

### 2. MODIFY: `thinpad_top.v`

插入 iCache 在 Core 和 MemCtrl 的指令路径之间：

```verilog
// 新增信号
wire icache_inst;
wire icache_stall;
wire icache_inst_req;
wire [31:0] icache_inst_addr;
wire total_mem_stall;

assign total_mem_stall = mem_stall | icache_stall;

// iCache 实例化
iCache icache (
    .clk(clk), .rst(rst),
    .core_pc(pc),
    .core_inst_req(inst_req),
    .core_inst(inst),
    .core_stall(icache_stall),
    .mem_inst_req(icache_inst_req),
    .mem_inst_addr(icache_inst_addr),
    .mem_inst_data(icache_inst),
    .mem_stall(mem_stall)
);

// MemCtrl 连接（指令路径改为通过iCache）
MemCtrl memctrl (
    // ...
    .inst_req(icache_inst_req),   // 原来是 inst_req
    .inst_addr(icache_inst_addr), // 原来是 pc
    .inst_data(icache_inst),      // 原来是 inst
    // ...
);

// Core 连接（stall 改为组合后的）
Core core (
    // ...
    .mem_stall(total_mem_stall),  // 原来是 mem_stall
    // ...
);
```

### 3. MODIFY: `headder.vh`

添加 Cache 参数宏：

```verilog
// iCache 参数
`define ICACHE_SETS        4
`define ICACHE_WAYS        4
`define ICACHE_BLOCK_WORDS 4
```

### 4. NO CHANGE: `core.v`
Core 的 mem_stall 输入已经存在，外部组合 stall 即可，核心逻辑不修改。

### 5. NO CHANGE: `MemCtrl.v`
MemCtrl 对指令请求和数据请求的处理逻辑不变。iCache 在 Miss 时向 MemCtrl 发起正常的指令请求。

---

## 五、替换策略：Round-Robin

每个 Set 维护一个 2 位计数器 `repl_ctr[set]`，记录下一个替换的 Way。发生 Miss 填充时：
1. 选 `repl_ctr[set]` 指向的 Way 替换
2. `repl_ctr[set] += 1`（模 WAYS）

不实现真正的 LRU（成本太高），Round-Robin 足够应付测试。

---

## 六、实现步骤（按顺序）

### Step 1: 更新 headder.vh
添加 `ICACHE_SETS`, `ICACHE_WAYS`, `ICACHE_BLOCK_WORDS` 宏定义

### Step 2: 编写 iCache.v
- Cache 存储寄存器声明
- 组合逻辑：地址解析 + Tag 比较 + 命中检测 + 数据输出
- 时序逻辑：MISS_FILL 状态机
- Round-robin 替换计数器
- core_stall 生成

### Step 3: 修改 thinpad_top.v
- 添加 iCache 实例化
- 重新连线：指令路径过 iCache，数据路径直连 MemCtrl
- 组合 stall 信号：`total_stall = icache_stall | memctrl_stall`

### Step 4: 仿真验证
- 用 labf.bin 仿真
- 观察第一次循环（冷缺失）vs 后续循环（Cache 命中）的取指时序
- 确认 regs 值与 Lab1/Lab2 一致

### Step 5: 截图 + 写报告
- 截图：冷缺失时的多周期 MemCtrl 访问 vs 命中时的单周期取指
- 报告：解释 Cache 前后指令取指的时序差异

---

## 七、验证标准

### 正确性
- labf.bin 和 testfile.bin 的 regs 值必须与 Lab1/Lab2 完全一致
- CPU 所有流水线行为不变（Cache 对外透明）

### 性能差异（报告用）
- **无 Cache（Lab2）**: 每条指令取指 ~4 周期（3 stall + 1 active）
- **有 Cache 冷缺失**: 首次访问一个 Block ~16 周期（4字 × 4周期/字）
- **有 Cache 命中**: 每条指令取指 1 周期（mem_stall=0, cache_hit=1）
- 在 labf 的大循环中，循环体指令在第一次迭代后被全部缓存，后续迭代的 IF 阶段大幅加速

---

## 八、注意事项

1. **组合逻辑时序**: Tag 比较和数据选择是组合路径，对 4 路 × 4 组的小 Cache，50MHz 下时序应满足。若 Vivado 报 timing violation，可改为"下周期命中"模式（加一级流水寄存器）

2. **复位后 Cache 状态**: 所有 valid 位清零。首次取指必然 Miss，通过 MemCtrl 填充后正常运行

3. **mem_stall 组合**: `total_stall = icache_stall | memctrl_stall`。在 Miss 填充期间，icache_stall=1 持续，Core 被冻结。MemCtrl 自身的 stall 也会经过 OR 门传到 Core

4. **与数据访存的交互**: 数据访存（LW/SW）仍然直连 MemCtrl，不受 iCache 影响。MemCtrl 的数据优先仲裁在 Cache Miss 填充期间仍然有效——如果数据请求和 Cache 填充的指令请求同时发生，数据优先

5. **死周期开销**: 每填一个字需要 1 个死周期更新地址，4 字 Block 需要额外 4 周期。总 Miss 开销 = 4字 × (4+1)周期 = ~20 周期。可以接受
