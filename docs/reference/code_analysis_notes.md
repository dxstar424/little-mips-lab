# LAB1 & LAB2 代码分析笔记

---

## 冒险概念总结

### 数据冒险（Data Hazard / RAW）
后一条指令需要读前一条指令正在写的寄存器。通过 **Forwarding（前推）** 解决：把 EX/MEM 阶段已算出但还没写回的结果直接传递给 ID 阶段。

### Load-Use 冒险
LW 指令后紧跟使用加载结果的指令。ALU 结果在 EX 阶段就有，但 LW 的结果要到 MEM 阶段才从 SRAM 读出来，forwarding 来不及。通过 **Stall（暂停）** 解决：阻塞 ID 阶段一周期，等 MEM 读完后再前推。

### 控制冒险（Control Hazard）
分支指令在 EX 阶段才知道是否跳转，但 IF 已取了下一指令。MIPS 用 **延迟槽（Delay Slot）** 解决：分支后的指令无论跳转与否都会执行。

### 前推优先级
EX 转发 > MEM 转发 > 寄存器文件默认值（regs_next）
EX 阶段数据比 MEM 阶段更新鲜。

---

## LAB2 多周期访存完整设计

### 1. 为什么要多周期访存

在 Lab1 中，CPU 假设内存访问在一个时钟周期内完成。但现实中 SRAM 芯片的访问时间（10-12ns）远大于寄存器读写（<1ns）。如果 CPU 用 50MHz 时钟（20ns 周期），一个周期刚好够一次 SRAM 访问——但这意味着时钟频率被内存瓶颈锁死了。

多周期访存的核心思想：**让 MEM 阶段等几个周期来访问慢速 SRAM，这样时钟频率可以大幅提高**。代价是 LW/SW 指令多花几个周期。

```
Lab1（单周期访存）:
IF  ID  EX  MEM  WB        MEM = 1周期 SRAM访问
[  ][  ][  ][SRAM][  ]     频率上限 = 1/SRAM延迟

Lab2（多周期访存）:
IF  ID  EX  MEM...MEM  WB  MEM = 多周期 SRAM访问
[  ][  ][  ][S][S][S][  ]  频率上限 = 1/ALU延迟（远高于SRAM）
```

但 Lab2 有个致命问题：**IF 阶段每次取指令也要访问 SRAM**，所以即使时钟频率提高了，每条指令还是要等 SRAM。真正的性能提升要等到 **Lab3 引入指令 Cache**。

---

### 2. Lab1 → Lab2 的架构变化

```
Lab1:  Core ←→ RAM (单周期，1个整体)

Lab2:  Core ←→ MemCtrl ←→ BaseRAM (代码段, 0x80000000-0x803FFFFF)
                          ←→ ExtRAM  (数据段, 0x80400000-0x807FFFFF)
                          ←→ UART    (串口,  0xBFD003F0)
```

Core 不再直接连 RAM，而是通过 MemCtrl 统一管理。MemCtrl 负责：
- 根据地址决定访问哪块芯片（地址映射 mmap）
- 生成物理 SRAM 需要的多周期时序
- 仲裁：数据访问和指令取指同时请求时，谁优先
- 通过 mem_stall 暂停 CPU 流水线等待内存完成

---

### 3. 异步 SRAM 和物理接口

#### 什么是异步 SRAM
"异步"意味着 SRAM **没有时钟输入**。它只响应控制信号的变化。你给出地址和读使能，等足够长时间（访问延迟），数据就出现在数据线上。如果等不够时间，数据是错的。

#### 控制信号（全部低有效）
物理 SRAM 芯片的控制信号名以 `_n` 结尾，表示低电平有效（active-low）：

| 信号 | 含义 | 低电平时 |
|------|------|----------|
| CE_n | Chip Enable（片选） | 芯片被选中，开始工作 |
| OE_n | Output Enable（输出使能） | 芯片驱动数据总线（读模式） |
| WE_n | Write Enable（写使能） | 芯片接收数据总线（写模式） |
| BE_n[3:0] | Byte Enable（字节使能） | 对应字节被选中 |

**为什么用低有效？** 历史原因——TTL 电路的默认上拉电平是高，低电平更可靠、抗噪声更好。

#### 字节使能 BE_n 的含义
SRAM 数据总线 32 位宽，分成 4 个字节。BE_n 每一位控制一个字节：

```
BE_n[3] → data[31:24]（最高字节）
BE_n[2] → data[23:16]
BE_n[1] → data[15:8]
BE_n[0] → data[7:0]（最低字节）
```

**低有效**所以 `be_n = 4'b1110` 表示：字节 0 使能（可以读写），字节 1/2/3 禁用。

#### 三态总线 inout
`base_ram_data` 和 `ext_ram_data` 是 `inout` 类型——同一组物理引脚既可读也可写。

```verilog
// MemCtrl.v:82-83
assign base_ram_data = drive_base ? txn_wdata : 32'bz;  // 写时驱动数据，读时高阻
```

`32'bz` 是高阻态（High-Z），相当于"断开连接"，让 SRAM 芯片驱动总线。

---

### 4. MemCtrl 状态机设计（MemCtrl.v）

MemCtrl 用一个 **4 状态 FSM** 管理每一次内存事务：

```
           any_req
  IDLE ─────────────→ READ（读事务）
    ↑                  │
    │                  ↓
    │               WAIT（等待SRAM响应）
    │                  │
    └──────────────────┘ wait_cnt到0
                       （回传读数据，释放stall）

           any_req+写请求
  IDLE ─────────────→ WRITE（写事务）
    ↑                   │
    │                   ↓
    │                WAIT（等待SRAM完成）
    │                   │
    └───────────────────┘
```

#### 状态详解

**IDLE**（空闲）：等待请求。有请求时锁存事务参数（地址、写数据、字节使能等），然后跳转到 READ 或 WRITE。

```verilog
// MemCtrl.v:121-137
S_IDLE: begin
    if (any_req) begin
        txn_is_inst  <= ~pick_data;        // 记下是指令取指还是数据访问
        txn_is_write <= pick_data ? req_is_write : 1'b0;
        txn_use_ext  <= req_use_ext;       // 用BaseRAM还是ExtRAM
        txn_addr     <= req_addr;
        txn_wdata    <= req_wdata;
        txn_be_n     <= req_be_n;
        // 跳转到 READ 或 WRITE
    end
end
```

**READ**：发起读操作。设置等待计数器，跳转到 WAIT。

**WRITE**：发起写操作。驱动数据总线，设置等待计数器，跳转到 WAIT。

**WAIT**：倒计数。最后一拍时回传读数据（如果是读事务），然后回到 IDLE。

#### 等待周期
```verilog
localparam [3:0] WAIT_SRAM = 4'd2;   // SRAM需要2个等待周期
localparam [3:0] WAIT_UART = 4'd8;   // UART需要8个等待周期（更慢）
```

对于 SRAM：READ/WRITE 状态 1 周期 + WAIT 2 周期 = **总共 3 周期** 完成一次访存。

#### 仲裁逻辑：数据优先
```verilog
// MemCtrl.v:74
wire pick_data = data_req;   // 有数据请求就选数据请求

// 这意味着：
// - 同时有指令请求和数据请求 → 先处理数据
// - 只有指令请求 → 处理指令取指
```

**为什么数据优先？** 因为 MEM 阶段的指令已经部分执行了（ALU 算出了地址），不能无限等。IF 阶段等一等只是晚取一条指令，不会出错。

---

### 5. mem_stall 信号流

这是 Lab2 最关键的设计。`mem_stall` 从 MemCtrl 产生，传到 Core，**冻结全部 5 级流水线**。

#### 产生（MemCtrl.v:79）
```verilog
assign mem_stall = (state != S_IDLE);  // 只要不在IDLE，就暂停CPU
```

事务开始时 state → READ/WRITE → WAIT，期间 mem_stall=1。事务结束 state → IDLE，mem_stall=0。

#### 传播（Core.v 中每一级）
```verilog
// IF/ID 寄存器（第144-147行）
else if(mem_stall)begin
    ifid_pc   <= ifid_pc;    // 保持不动
    ifid_inst <= ifid_inst;  // 保持不动
end

// ID/EX 寄存器（第254-272行）
else if(mem_stall)begin
    idex_pc <= idex_pc;      // 保持不动
    // ... 所有ID/EX信号都保持
end

// EX/MEM 寄存器（第356-365行）
else if(mem_stall)begin
    exmem_alu_out <= exmem_alu_out;  // 保持不动
    // ...
end

// WB 阶段（第403行）
if(~mem_stall)begin           // 只有不stall时才更新WB
    wb_rd <= exmem_rd;
    // ...
end

// PC 更新（第107-112行）
else if (fit & (~mem_stall))   // mem_stall时禁止PC跳转
else if((~if_stall) & (~mem_stall))  // mem_stall时禁止PC递增
```

**效果**：当 MemCtrl 在处理任何访存请求时，整个 CPU 管线原地踏步。所有寄存器保持当前值，所有状态机暂停。

---

### 6. 地址映射（mmap）

```verilog
// MemCtrl.v:67-68
wire req_use_ext = req_addr[22];                    // bit22=1 → ExtRAM
wire req_is_uart = (req_addr[31:4] == 28'hbfd003f); // 0xBFD003Fx → UART
```

| 地址范围 | bit[22] | 目标 |
|----------|---------|------|
| 0x80000000 - 0x803FFFFF | 0 | BaseRAM（代码段） |
| 0x80400000 - 0x807FFFFF | 1 | ExtRAM（数据段） |
| 0xBFD003F0 - 0xBFD003FF | - | UART 串口 |

SRAM 只有 20 根地址线（1M 字 × 32 位 = 4MB），所以物理地址是 `txn_addr[21:2]`（跳过最低 2 位因为 32 位按字对齐）。

---

### 7. 字节使能（Byte Enable）的完整链路

这是 LB/SB 指令正确性的关键。以 **LB $1, 1($2)**（从地址 0x80400001 读一个字节）为例：

#### Core 中（core.v:322-326）
```verilog
assign ex_be = (~idex_dmem_use_be)?4'b0000:     // 不是字节操作 → 全选通
              (~|(ex_addr[1:0] ^ 2'b00))?4'b1110:  // 字节0
              (~|(ex_addr[1:0] ^ 2'b01))?4'b1101:  // 字节1
              (~|(ex_addr[1:0] ^ 2'b10))?4'b1011:  // 字节2
                                          4'b0111;  // 字节3
```

地址 0x80400001 → addr[1:0] = 01 → `ex_be = 4'b1101`（字节1使能，注意是低有效编码）

#### MemCtrl 中
`ex_be` 直接传给 SRAM 的 `be_n`：
```verilog
assign base_ram_be_n = cs_base ? txn_be_n : 4'b1111; // 未选中时全禁用
```
SRAM 看到 `be_n = 4'b1101`，只使能 data[15:8]（字节1），返回该字节。

#### Core 中字节提取（core.v:388-392）
```verilog
assign dmem_rdata_be = 
    (~|(be ^ 4'b1110))? {{24{dmem_rdata[7]}}, dmem_rdata[7:0]}:
    (~|(be ^ 4'b1101))? {{24{dmem_rdata[15]}}, dmem_rdata[15:8]}:
    ...
```

LB 需要对读到的字节做**符号扩展**：把字节的最高位复制到高 24 位。这符合 MIPS 规范——LB 是有符号加载。

---

### 8. 写缓冲（Write Buffer）

#### 概念
Lab2 要求实现写缓冲策略。核心思想：当 CPU 执行 SW 指令时，不需要等 SRAM 真正写完。把写地址和数据暂存在一个寄存器里，CPU 继续跑，写操作在后台完成。

```
无写缓冲:  SW → stall CPU 3周期 → 继续
有写缓冲:  SW → 缓存数据（1周期）→ CPU继续 → 后台写入SRAM
```

#### 当前实现的状态
你的 MemCtrl **没有真正实现写缓冲**。SW 指令仍然经过完整的 WRITE→WAIT→IDLE 流程，CPU 被阻塞 3 个周期。这是 Lab2 报告中可以讨论的改进点。

要加入写缓冲，需要：
1. 添加一个 FIFO 或寄存器保存待写入的数据
2. SW 请求到达时立即接受并释放 stall，数据在后台写入
3. 如果写缓冲满了，仍需 stall
4. 读请求需要检查写缓冲（如果读地址匹配未完成的写地址，需要转发数据）

---

### 9. 完整信号追踪：LW 指令从取指到写回

以 `LW $8, 0($9)` 为例，假设 $9 = 0x80400000：

#### IF（取指）
```
Core: inst_req=1, pc=0x80000000
MemCtrl: IDLE→READ→WAIT(2周期)→IDLE
         mem_stall=1 持续3周期
         最后: inst_data = base_ram_data读出的指令
Core: 收到inst[31:0]，ifid_inst锁存指令
```

#### ID（译码）
```
Decode: opcode=100011(LW) → reg_wen=1, A=A_RS, B=B_SI,
        alu_type=ADD, dmem_ren=1, datatoreg=1
regfile: rs_val=$9=0x80400000, rt_val=无关
forward: 检查是否有数据冒险，转发或使用寄存器值
```

#### EX（执行）
```
ALU: alu_a_val=0x80400000, alu_b_val=0x00000000 → ex_alu_out=0x80400000
ex_addr = 0x80400000 + 0 = 0x80400000
ex_be = 4'b0000 (非字节操作，全选通)
ex_wdata = 无关
```

#### MEM（访存）——这是多周期的核心
```
Core输出: data_req=1, data_we=0, dmem_addr=0x80400000, be=4'b0000
MemCtrl: IDLE→READ(锁存)→WAIT(2周期)→IDLE
         ext_ram_ce_n=0, ext_ram_oe_n=0 (读ExtRAM)
         ext_ram_addr = 0x80400000[21:2] = 0x010000 (字地址)
         ext_ram_be_n = 4'b0000 (全字节选通)
         mem_stall=1 → 整个CPU暂停
         最后: data_rdata = ext_ram_data (SRAM返回的32位数据)
```

#### WB（写回）
```
dmem_rdata_be = dmem_rdata (全字，不需要字节提取)
wb_data = dmem_rdata_be (datatoreg=1，选内存数据)
wb_rd = $8, wb_reg_w = 1
regfile: regs[8] ← wb_data
```

---

### 10. 关键设计问题回答

#### 为什么多周期访存没有提高运行效率？（Lab2 报告思考题）
因为 IF 阶段每次取指令都经过 MemCtrl，每次都要等 3 个周期的 SRAM 访问。即使时钟频率提高了，CPI 也因此变大（每条指令的 IF 和 MEM 都更慢）。**必须在 Lab3 加入指令 Cache** 才能真正利用高频优势——Cache 命中时只需 1 周期取指，绕过 SRAM 延迟。

#### mem_stall 释放时机
当前代码在 WAIT 状态的**最后一拍**（wait_cnt=1 的下一个周期）回传数据并释放 stall。这意味着数据在 state→IDLE 的同一周期对 Core 可见。Core 在下一个时钟沿锁存数据。

#### 三种请求的优先级
- 数据请求 > 指令请求（数据优先）
- 不打断：一旦事务开始（进入 READ/WRITE），新请求必须等待当前事务完成（回到 IDLE）
- 这保证了 SRAM 控制信号的稳定性

---

## 逐模块 Bug 列表

### Bug 1 [高，已修复] core.v:355 — 位宽不匹配
- `reg [3:0] exmem_be;` 声明 4 位
- `exmem_be <= 3'b0;` 只复位 3 位（bit[3] 未复位）
- 已修复为 `exmem_be <= 4'b0;`

### Bug 2 [中，已修复] core.v:368 — 地址信号语义错误
- `exmem_addr <= ex_alu_out;` 应改为 `exmem_addr <= ex_addr;`
- 恰好能工作是因为 LW/SW 的 ALU 运算是 ADD，结果和地址计算一致
- 已修复

### Bug 3 [中，已修复] alu.vhd:210 — J/JAL 跳转地址
- MIPS 规范要求用 `(PC+4)[31:28]`，代码用了 `PC[31:28]`
- 跨 256MB 边界时跳转地址高 4 位会错
- 已修复为 `std_logic_vector(unsigned(pc) + 4)(31 downto 28)`

### Bug 4 [高] alu.vhd — 乘法器延迟假设
- 状态机假设 IP 核恰好 2 周期出结果
- 需在 Vivado 确认 mult_gen_0 的流水线配置

### Bug 5 [低] regfile.v — 硬件开销大
- generate for 循环生成 31 个比较器 + MUX
- FPGA 综合后消耗大量 LUT（不影响功能）

### Bug 6 [低] MemCtrl.v — UART 未实现
- 读写返回恒 0
- Lab2 测试可能不涉及，龙芯杯需要

### Bug 7 [低] Decode.vhd — LUI 未显式设 use_rs
- 不影响功能，但代码可读性差

### Bug 8 [中] MemCtrl.v — 写缓冲未实现
- Lab2 要求实现写缓冲策略，当前 SW 仍阻塞 CPU 3 周期
- 不影响正确性，但性能未达要求
- 报告中应说明改进方向

---

## LAB3 实现记录（2026-05-03）

详见 `docs/lab3/implementation_log.md`

### 改动清单

| 文件 | 操作 | 说明 |
|------|------|------|
| headder.vh | +4行 | ICACHE_SETS/WAYS/BLOCK_WORDS 宏 |
| iCache.v | **新建** (191行) | 4路组相联指令Cache |
| thinpad_top.v | +25行 | iCache插入Core↔MemCtrl指令路径 |
| core.v | 不动 | - |
| MemCtrl.v | 不动 | - |

### 关键设计点

1. **组合 core_stall**: 缺失瞬间冻结Core，避免假指令注入
2. **stall_cycle提前地址更新**: 在MemCtrl最后stall周期更新地址，消除死周期
3. **data_req监听**: 区分数据访存 vs Cache填充

### Cache参数
- 4组 × 4路 × 4字 = 64条指令（256字节）
- 地址: [31:6]Tag [5:4]Index [3:2]Word [1:0]忽略
- 替换策略: Round-Robin
- 命中时序: 同周期（组合逻辑）
