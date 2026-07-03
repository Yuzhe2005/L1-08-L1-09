# RTL Design V2 Architecture Report

## 1. 总体设计目标

`RTL_design_v2` 是 Base Plan 的完整 RTL 结构。当前设计只有两个正式 mode：

```text
BASE_PLAN_V2_MODE_SINGLE
BASE_PLAN_V2_MODE_BUFFERED_PARALLEL
```

两条 path 的目标不同：

```text
single mode:
    面向 Fclk >= Fsample
    一个 valid input sample 进入 single compute chain

buffered-parallel mode:
    面向 Fclk < Fsample
    input sample 先进入 async input buffer，再以 full bundle 形式进入 parallel compute chain
```

最终 top-level 输出统一为 scalar IQ stream：

```text
y_i / y_q / y_valid / y_ready
```

也就是说，parallel path 内部虽然使用 bundle 计算，但最终经过 output buffer 拆回一个 IQ 一个 IQ 输出。

## 2. 文件结构

当前主要 RTL 文件如下：

```text
base_plan_v2_top.sv          完整 Base Plan v2 top

l1_08_v2_pkg.sv              L1-08 参数定义
l1_08_single_core.sv         L1-08 single FIR core、FIR MAC、coefficient bank
l1_08_parallel_core.sv       L1-08 parallel FIR core
l1_08_input_buffer.sv        sample-to-bundle async input buffer

l1_09_v2_pkg.sv              L1-09 参数定义
l1_09_single_core.sv         L1-09 single all-pass IIR core
l1_09_parallel_core.sv       L1-09 parallel all-pass IIR core
l1_09_output_buffer.sv       bundle-to-sample async output buffer

coeff/l1_08_fir_coeff_reset.svh        L1-08 FIR fixed coefficients
coeff/l1_09_allpass_coeff_reset.svh    L1-09 all-pass fixed coefficients
```

推荐 compile order：

```text
1. l1_08_v2_pkg.sv
2. l1_09_v2_pkg.sv
3. l1_08_single_core.sv
4. l1_08_parallel_core.sv
5. l1_08_input_buffer.sv
6. l1_09_single_core.sv
7. l1_09_parallel_core.sv
8. l1_09_output_buffer.sv
9. base_plan_v2_top.sv
```

## 3. Top-Level 数据流

### Single Mode

```text
x_i / x_q / in_valid
    -> L1-08 single FIR
    -> L1-09 single all-pass IIR
    -> output buffer, PARALLEL_FACTOR = 1
    -> y_i / y_q / y_valid
```

single mode 不使用 input buffer。  
它假设 compute clock `clk` 足够快，能直接处理输入 sample stream。

### Buffered-Parallel Mode

```text
x_i / x_q / in_valid
    -> L1-08 input buffer
    -> L1-08 parallel FIR
    -> L1-09 parallel all-pass IIR
    -> L1-09 output buffer
    -> y_i / y_q / y_valid
```

buffered-parallel mode 中，外部仍然是一个 IQ 一个 IQ 输入。  
`l1_08_input_buffer` 会把连续 sample 打包成 full bundle，然后送入 parallel compute chain。

## 4. Clock Domain

当前 top 有三个 clock domain：

```text
sample_clk:
    input buffer write side
    接收外部 input sample

clk:
    compute domain
    L1-08 / L1-09 compute core 都在这个 domain

output_clk:
    output buffer read side
    向下游输出 scalar IQ stream
```

因此 buffered-parallel path 的跨时钟关系是：

```text
sample_clk -> input buffer -> clk -> output buffer -> output_clk
```

## 5. L1-08 结构

### L1-08 Single Core

`l1_08_v2_core_single` 是 scalar FIR core：

```text
input one IQ sample
    -> FIR MAC
    -> output one IQ sample
```

当前 single FIR 的 MAC window 使用：

```text
current input + old history
```

因此 accepted input sample 和 MAC 计算窗口是对齐的。

### L1-08 Parallel Core

`l1_08_v2_core_parallel` 一次处理一个 full bundle：

```text
x_i[0 : PARALLEL_FACTOR-1]
x_q[0 : PARALLEL_FACTOR-1]
```

bundle 顺序是 chronological：

```text
lane 0 是最旧 sample
lane PARALLEL_FACTOR-1 是最新 sample
```

top 中 parallel core 的 `active_lanes` 固定为 full bundle：

```text
active_lanes = PARALLEL_FACTOR
```

因此正式 top 不支持 partial bundle input。

## 6. L1-09 结构

### L1-09 Single Core

`l1_09_v2_single_core` 是 scalar all-pass IIR cascade。  
它由多个 second-order all-pass section 串接组成。

当前 single core 使用 per-section valid pipeline：

```text
stage_valid[0] = input valid
stage_valid[1] <= stage_valid[0]
stage_valid[2] <= stage_valid[1]
...
```

也就是说，一个 valid sample 进入 section 0 后，会每个 clock 往后推进一级，直到最终 output valid。

### L1-09 Parallel Core

`l1_09_v2_parallel_core` 是 bundle version 的 all-pass IIR cascade。  
它和 single core 一样使用 per-section valid pipeline，只是每一级处理的是一个 full bundle。

每个 parallel section 内部会按 lane 顺序计算 bundle：

```text
lane 0 -> lane 1 -> ... -> lane PARALLEL_FACTOR-1
```

计算完成后，该 section 的 IIR state 更新到 bundle 最后两个 sample 对应的状态。

## 7. Buffer 结构

### Input Buffer

`l1_08_v2_input_buffer` 是 sample-to-bundle async FIFO。

write side：

```text
wr_clk = sample_clk
input  = one IQ sample
```

read side：

```text
rd_clk = clk
output = one full bundle
```

它的作用是：

```text
连续接收 scalar IQ sample
攒够 PARALLEL_FACTOR 个 sample
写入 async FIFO
compute side 每次读出一个 full bundle
```

input buffer 和 L1-08 parallel core 之间有 valid-ready handshake：

```text
input_buffer_out_valid && input_buffer_out_ready
```

只有 parallel compute chain ready 时，input buffer 才 pop 一个 bundle。

### Output Buffer

`l1_09_v2_output_buffer` 是 bundle-to-sample async FIFO。

write side：

```text
wr_clk = clk
input  = one full bundle
```

read side：

```text
rd_clk = output_clk
output = one IQ sample
```

它按顺序输出：

```text
lane 0 -> lane 1 -> ... -> lane PARALLEL_FACTOR-1
```

output buffer 和下游之间有 valid-ready handshake：

```text
y_valid && y_ready
```

当前设计假设 output buffer 足够大，因此 L1-09 parallel 不接收来自 output buffer 的 backpressure。  
如果 output buffer 满了，会拉高：

```text
output_buffer_overflow_error
```

## 8. 关键信号连接

### Top-Level Input

```text
in_valid:
    上游 input sample 有效

input_ready:
    当前 mode 下 top 可以接收 input sample
```

single mode 中：

```text
input_ready = L1-08 single ready && L1-09 single ready
```

buffered-parallel mode 中：

```text
input_ready = input buffer write side ready
```

### L1-08 Parallel to L1-09 Parallel

```text
L1-09 parallel input valid = &L1-08 parallel y_valid
```

由于 top 固定 full bundle，所以只有 L1-08 parallel 所有 lanes 都 valid 时，L1-09 parallel 才接收 bundle。

### Final Output

```text
y_valid:
    top 当前输出 IQ sample 有效

y_ready:
    下游可以接收当前 IQ sample
```

single 和 buffered-parallel 两条 path 的输出都经过 output buffer，因此最终接口保持一致。

## 9. 当前设计假设

当前 RTL 依赖以下假设：

```text
1. 系统只有两个 mode：single 和 buffered-parallel。
2. buffered-parallel path 内部永远使用 full bundle。
3. L1-09 parallel 输出到 output buffer 时不做 backpressure。
4. output buffer 被认为足够大；如果实际满了，用 overflow_error 报错。
5. startup transient 不在 compute core 内部丢弃，由系统外层决定是否 mask。
6. BUFFER_DEPTH / PARALLEL_FACTOR 应按 2 的幂配置，以匹配 async FIFO pointer 逻辑。
```

## 10. 总结

当前 `RTL_design_v2` 的核心结构是：

```text
Fclk >= Fsample:
    single mode
    L1-08 single -> L1-09 single

Fclk < Fsample:
    buffered-parallel mode
    input buffer -> L1-08 parallel -> L1-09 parallel -> output buffer
```

L1-08 负责 magnitude compensation，L1-09 负责 phase / group-delay compensation。  
input buffer 解决高速 sample 写入和 compute clock 不匹配的问题，output buffer 解决 parallel bundle 输出与 scalar downstream output 的接口问题。
