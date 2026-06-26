下面我按“完全没看过解释”的方式重新讲整个 `RTL_design_v2`。先抓住总结构：

```text
base_plan_l1_08_v2_pkg.sv     放公共参数和 mode 定义
L1-08_single.sv               放系数 bank、FIR MAC、single core
L1-08_parallel.sv             放 dynamic parallel compute core
top.sv                        顶层 mode selection
coeff/l1_08_fir_coeff_reset.svh  80 tap 固定系数
```

**整体数据流**

`top.sv` 是入口。它根据 `mode` 选择：

```text
L1_08_MODE_SINGLE   -> 使用 l1_08_v2_core_single
L1_08_MODE_PARALLEL -> 使用 l1_08_v2_core_parallel
L1_08_MODE_BUFFERED -> 目前保留，还没实现
```

single mode 是：

```text
每个 clk 最多输入 1 个 IQ sample -> 输出 1 个 IQ result
```

parallel mode 是：

```text
每个 clk 最多输入 PARALLEL_FACTOR 个 IQ sample
active_lanes 告诉它这一拍实际有几个 sample
```

---

**1. Package 文件**

[base_plan_l1_08_v2_pkg.sv](C:/Users/bjwb0005/Documents/Rigol_work/L1-08+L1-09/RTL_design_v2/base_plan_l1_08_v2_pkg.sv:1)

第 1 行：

```systemverilog
`default_nettype none
```

要求所有 signal 必须显式声明，防止拼写错误变成隐式 wire。

第 3 行：

```systemverilog
package base_plan_l1_08_v2_pkg;
```

定义一个 package，里面放公共参数。

第 4-8 行：

```systemverilog
typedef enum logic [1:0] {...} l1_08_mode_e;
```

定义 mode 类型：

```text
0 -> single
1 -> parallel
2 -> buffered
```

第 10 行：

```systemverilog
TAP_NUM_DEFAULT = 80
```

L1-08 FIR 是 80 tap。

第 11-12 行：

```systemverilog
GROUP_DELAY_SAMPLES = 39
FIR_SETTLE_SAMPLES = 79
```

这是 FIR 的延迟/settle 相关参数。80 tap FIR 要等足够多 sample 后输出才可靠。

第 14-18 行：

```systemverilog
DATA_WIDTH = 16
COEFF_WIDTH = 16
COEFF_FRAC_BITS = 13
ACCUM_EXTRA_BITS = 7
```

表示输入输出是 16-bit，系数是 16-bit Q 格式，系数小数位是 13。

第 19-21 行：

```systemverilog
ACCUM_WIDTH = DATA_WIDTH + COEFF_WIDTH + ACCUM_EXTRA_BITS
```

MAC accumulator 位宽，比输入和系数更宽，防止乘加溢出。

第 22-24 行：

```systemverilog
MAC_LATENCY_DEFAULT = 7
SINGLE_OUTPUT_LATENCY = 8
PARALLEL_FACTOR_DEFAULT = 4
```

MAC pipeline 默认 7 级，总输出对齐 latency 用 8。默认最多 4-lane parallel。

第 27-29 行：

```systemverilog
`define BASE_PLAN_L1_08_V2_COEFF_RESET_SVH "coeff/l1_08_fir_coeff_reset.svh"
```

定义系数 include 文件路径。

---

**2. Top 文件**

[top.sv](C:/Users/bjwb0005/Documents/Rigol_work/L1-08+L1-09/RTL_design_v2/top.sv:5)

第 5-13 行：定义 `l1_08_v2_top` 参数。它把 package 里的默认参数拿进来，尤其是：

```text
TAP_NUM = 80
PARALLEL_FACTOR = 4
ACTIVE_LANES_W = 表示 0~4 需要的 bit 数
```

第 15-24 行：输入端口。

```text
clk/reset_n       时钟和 reset
mode              选择 single/parallel/buffered
x_i/x_q           single mode 的 scalar 输入
parallel_x_i/q    parallel mode 的 array 输入
parallel_active_lanes 这一拍 parallel 有几个 sample 有效
in_valid          输入有效
bypass            直接旁路，不做 FIR
```

第 25-33 行：输出端口。

```text
y_i/y_q/y_valid                   single 输出
parallel_y_i/q/parallel_y_valid   parallel 输出
coeffs_ready                      系数 ready
mode_supported                    当前 mode 是否支持
mode_error                        mode 或 active_lanes 是否非法
```

第 35-49 行：内部 signal。  
这些 signal 用来连接 top 和两个 core：

```text
single_*   连接 single core
parallel_* 连接 parallel core
```

第 51-62 行：mode decode。

```systemverilog
single_mode = mode == SINGLE
parallel_mode = mode == PARALLEL
```

然后：

```text
single_in_valid   只在 single mode 时传给 single core
parallel_in_valid 只在 parallel mode 时传给 parallel core
```

第 55-56 行：

```systemverilog
single_clear = !single_mode
parallel_clear = !parallel_mode
```

意思是：不在某个 mode 时，就清空对应 core，防止旧 pipeline 结果冒出来。

第 57-59 行：

```systemverilog
mode_supported = single 或 parallel
mode_error = unsupported mode 或 parallel_active_lanes_error
```

第 60-62 行：根据当前 mode 选择 `coeffs_ready` 来源。

第 64-83 行：实例化 single core。  
single core 接 scalar `x_i/x_q`，输出 scalar `single_y_i/q`。

第 85-108 行：实例化 parallel core。  
parallel core 接 array `parallel_x_i/q` 和 `parallel_active_lanes`，输出 array `parallel_core_y_i/q`。

第 110-118 行：组合逻辑默认输出清零。  
这是好习惯，避免 latch。

第 120-146 行：根据 mode 选择输出。

```text
single mode   -> scalar y_i/y_q/y_valid
parallel mode -> parallel_y_i/q/valid
buffered mode -> 暂时输出 0
default       -> 输出 0
```

---

**3. Single 文件里的 coefficient bank**

[L1-08_single.sv](C:/Users/bjwb0005/Documents/Rigol_work/L1-08+L1-09/RTL_design_v2/L1-08_single.sv:5)

第 5-13 行：定义 `l1_08_v2_coeff_bank`。  
它的工作是提供 80 个 FIR 系数。

第 14 行：

```systemverilog
coeff_mem [TAP_NUM]
```

真正存 coefficient 的寄存器数组。

第 16 行：

```systemverilog
assign coeff = coeff_mem;
```

把内部系数数组连到输出端口。

第 17 行：

```systemverilog
coeffs_ready = reset_n;
```

reset 结束后就认为系数 ready。

第 19-23 行：

```systemverilog
if (!reset_n) begin
    `include coeff file
end
```

reset 时加载固定系数。系数来自 [l1_08_fir_coeff_reset.svh](C:/Users/bjwb0005/Documents/Rigol_work/L1-08+L1-09/RTL_design_v2/coeff/l1_08_fir_coeff_reset.svh:1)。

---

**4. Single 文件里的 FIR MAC**

[L1-08_single.sv:26](C:/Users/bjwb0005/Documents/Rigol_work/L1-08+L1-09/RTL_design_v2/L1-08_single.sv:26)

第 26-37 行：定义 `l1_08_v2_fir_mac`。  
它输入：

```text
sample_window[80]
coeff[80]
```

输出：

```text
mac_out
```

也就是做：

```text
sum(sample_window[i] * coeff[i])
```

第 38 行：

```systemverilog
PROD_W = DATA_W + COEFF_W
```

乘法结果位宽。

第 39-44 行：计算每一级 adder tree 的节点数量。  
80 个 product 两两相加：

```text
80 -> 40 -> 20 -> 10 -> 5 -> 3 -> 2 -> 1
```

第 46 行：

```systemverilog
prod[TAP_NUM]
```

80 个乘法结果。

第 47-52 行：

```systemverilog
s1, s2, s3, s4, s5, s6
```

adder tree 每一级 pipeline register。

第 54-59 行：

```systemverilog
prod[tap] = sample_window[tap] * coeff[tap]
```

并行生成 80 个乘法。

第 61-81 行：reset 时清空所有 adder pipeline 和 `mac_out`。

第 83-135 行：每个 clock 推进一级加法树。  
每一级都是“两两相加，如果剩一个就直接传下去”。这就是 FIR MAC 的 pipeline。

---

**5. Single Core**

[L1-08_single.sv:140](C:/Users/bjwb0005/Documents/Rigol_work/L1-08+L1-09/RTL_design_v2/L1-08_single.sv:140)

第 140-158 行：定义 single core 接口。

```text
输入一个 x_i/x_q
输出一个 y_i/y_q
```

第 160-176 行：内部控制。

```text
FullWindowSamples = 80
OUTPUT_LATENCY = MAC_LATENCY + 1
i_window/q_window 是 80 tap shift register
mac_valid_pipe 对齐 MAC output valid
sample_count 记录已经输入了多少 sample
```

第 178-186 行：实例化 coefficient bank。

第 188-212 行：实例化 I 路 MAC 和 Q 路 MAC。  
I 和 Q 用同一套系数，但 sample window 不同。

第 214-242 行：`round_sat_q15`。  
MAC 输出是宽位宽，最终要回到 16-bit，所以这里做：

```text
rounding
右移 COEFF_FRAC_BITS
saturation 到 -32768~32767
```

第 244-254 行：reset 或 clear 时清空 window、valid pipe、输出、sample_count。

第 256-257 行：valid pipe 每个 clock 推进。  
因为 MAC pipeline 每个 clock 都推进，valid 也必须每个 clock 推进。

第 259-265 行：如果 `run_valid`，shift window，并把新 sample 放到 `window[0]`。

第 267-269 行：sample_count 加 1，最多加到 80。

第 271-274 行：bypass 时直接输出输入 sample。

第 276-284 行：如果 MAC result valid，就 round/saturate 后输出；否则输出 invalid。

第 286-294 行：即使这一拍没有新 input，旧的 MAC pipeline 结果也可能出来，所以仍然检查 `mac_out_valid`。

---

**6. Parallel Core**

[L1-08_parallel.sv](C:/Users/bjwb0005/Documents/Rigol_work/L1-08+L1-09/RTL_design_v2/L1-08_parallel.sv:5)

第 5-13 行：定义 parallel core 参数。  
最重要的是：

```text
PARALLEL_FACTOR      最大 lane 数，默认 4
ACTIVE_LANES_W       active_lanes 的 bit width
```

第 15-27 行：parallel core 接口。

```text
x_i/q[PARALLEL_FACTOR]   输入 bundle
active_lanes             这一拍实际有几个 sample
y_i/q[PARALLEL_FACTOR]   输出 bundle
y_valid                  每个 lane 独立 valid
active_lanes_error       active_lanes 是否非法
```

第 29-30 行：FIR 需要 80 个 sample 才开始 valid；MAC output latency 是 `MAC_LATENCY + 1`。

第 32-33 行：

```systemverilog
i_history/q_history
```

保存当前 bundle 之前的历史 sample。

第 34-35 行：

```systemverilog
i_lane_window/q_lane_window
```

每个 lane 自己的 FIR window。

如果 `active_lanes=3`，这一拍：

```text
lane0 算 sample n
lane1 算 sample n+1
lane2 算 sample n+2
```

第 36-45 行：系数、MAC 输出、valid pipe、lane_active、sample_count 等内部状态。

第 47-52 行：把 `active_lanes` 转成 integer，并 clamp 到最大值，避免数组越界。

第 54 行：如果 `active_lanes > PARALLEL_FACTOR`，拉高 error。

第 55-58 行：`run_valid` 成立条件：

```text
in_valid
coeffs_ready
没有 active_lanes_error
active_lanes 不是 0
```

第 61-69 行：实例化 coefficient bank。

第 71-80 行：generate 每个 lane。  
第 75 行判断这个 lane 是否 active。  
第 76-79 行判断这个 lane 的 FIR output 是否已经有完整 80 tap window。  
第 80 行取 valid pipe 最后一位作为输出 valid。

第 82-90 行：parallel 正确性的核心，构造每个 lane 的 FIR window。

假设：

```text
active_lanes=4
x[0]=sample n
x[1]=sample n+1
x[2]=sample n+2
x[3]=sample n+3
```

则：

```text
lane0 window = x[0], history[0], history[1], ...
lane1 window = x[1], x[0], history[0], ...
lane2 window = x[2], x[1], x[0], ...
lane3 window = x[3], x[2], x[1], x[0], ...
```

所以 parallel 一拍算 4 个连续 sample，等价于 single 连续跑 4 拍。

第 92-116 行：每个 lane 实例化 I MAC 和 Q MAC。  
默认 4 lane 时，就是：

```text
4 lanes * I/Q = 8 个 FIR MAC
```

第 120-148 行：parallel 版本自己的 `round_sat_q15`，功能和 single 一样。

第 150-162 行：reset 或 clear 时清空 history、valid pipe、输出和 sample_count。

第 164-168 行：每个 clock 推进所有 lane 的 valid pipe。

第 170-179 行：如果这一拍真的消费 input，就按 `active_lane_count` 更新 history。

例如 `active_lanes=3`：

```text
history[0]=x[2]
history[1]=x[1]
history[2]=x[0]
history[3]=old history[0]
```

第 181-185 行：sample_count 加上 `active_lane_count`，最多到 80。

第 187-203 行：如果 run_valid，处理输出。  
bypass 且 lane active 时，直接输出输入；否则如果 MAC result valid，就输出 FIR result。

第 204-216 行：如果这一拍没有新 input，也仍然可能有旧 pipeline result 出来，所以继续检查 `lane_out_valid`。

---

**7. Coeff 文件**

[coeff/l1_08_fir_coeff_reset.svh](C:/Users/bjwb0005/Documents/Rigol_work/L1-08+L1-09/RTL_design_v2/coeff/l1_08_fir_coeff_reset.svh:1)

第 1-3 行：说明这是自动生成的 coefficient init 文件，profile 是：

```text
bw_1g, tap80, Q16.13
```

第 4-83 行：80 个 coefficient：

```systemverilog
coeff_mem[0] <= ...
...
coeff_mem[79] <= ...
```

这些就是 FIR 的 h[0] 到 h[79]。

---

**最重要的理解**

v2 的核心不是一个 module，而是一套结构：

```text
top 负责选 mode
single core 负责一拍一个 sample
parallel core 负责一拍 0~4 个 sample
coeff bank 提供 80 tap 系数
fir_mac 做真正的乘加卷积
```

parallel 正确性的根本原因是：

```text
每个 active lane 构造出来的 FIR window
等价于 single core 在对应时间点看到的 FIR window
```

所以：

```text
single 连续跑 4 拍
和
parallel 一拍跑 4 lane
```

在数学上应该得到同样的 4 个 FIR 输出。当前还需要 testbench 做逐点对比验证，这是下一步最关键的验证工作。
