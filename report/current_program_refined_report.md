# 当前进度总结

GitHub repository: [Yuzhe2005/L1-08-L1-09](https://github.com/Yuzhe2005/L1-08-L1-09)

## 1. 总体概述

上周运行 sweep test 暴露出一个关键问题：旧版本 L1-09 回归程序在部分 seed 下没有找到真正有效的 all-pass 参数，而是让多个 section 收敛到非常接近的位置。这样得到的 group delay 图像看起来接近 constant group delay，但实际不是有效补偿，而是 optimizer 卡住造成的异常结果。针对这个问题，我修改了 L1-09 的参数搜索方式，把 section 的角频率参数改成 ordered theta / section 间隔参数表达，降低多个 section collapse 到同一位置的风险。

同时，我也对 simulation pipeline 做了重构，把 Base Plan 的 L1-08、L1-09、full chain 和 Plan B 的 complex FIR 流程拆得更清楚，并统一整理 run summary 和输出路径，方便后续 sweep test、debug 和导出 RTL 系数。

Plan B 也已经加入程序。Plan B 使用 single complex FIR 同时补偿 magnitude 和 phase/group delay。从 sweep 观察看，Plan B 的效果不错，但它需要大量 complex FIR taps，对应的 multiplier、coefficient memory 和 adder tree 资源明显高于 Base Plan。因此当前 RTL 编码阶段仍选择 Base Plan；Plan B 保留为性能更强但资源更重的候选架构。

完整 sweep test 结果和图像目前在公司电脑里，没有 push 到 git repo。因此本报告不引用具体 sweep 图像，只总结已经观察到的问题、程序修改和当前架构选择。

## 2. Sweep Test 问题发现

上周我运行 Base Plan sweep test 时，发现 L1-09 all-pass 设计在部分 seed 下表现不稳定。问题不是程序 crash，而是 optimizer 找到的参数组合不合理：多个 all-pass section 的参数几乎一样，等价于把很多 section 堆在同一个频率位置附近。

这个现象会带来两个问题。第一，多个 section 重复作用在同一个区域，会浪费 section 数量，导致其他频段的 group delay ripple 没有被有效补偿。第二，从图像上看，经过 L1-09 后的 group delay 可能变得像一条比较平的 constant group delay，但这并不代表真实补偿有效，因为它可能只是 optimizer 对目标函数的一个坏局部解。

旧版回归的问题主要在于 section 参数自由度太松。每个 section 都有 `r` 和 `theta`，如果 `theta` 没有合理的顺序约束或间隔控制，least-squares 在某些 seed 下可能让多个 `theta` 收敛到相似值。这样会导致 all-pass group-delay peak 重叠，无法形成覆盖全 band 的补偿形状。

这个问题通过 sweep test 才比较容易暴露。单个 seed 的结果可能看起来正常，但多个 seed、不同 H1 phase/group-delay 形状下，optimizer 的鲁棒性问题会更明显。
## 3. L1-09 回归修正

L1-09 的目标是用多级 second-order all-pass IIR 补偿 L1-08 之后剩余的 group-delay ripple。它不改变 magnitude，只改变 phase/group delay。每个二阶 all-pass section 的数学形式是：

```text
H_ap(z) = (r^2 - 2r cos(theta) z^-1 + z^-2)
          / (1 - 2r cos(theta) z^-1 + r^2 z^-2)
```

这里每个 section 只有两个独立参数：

- `r`：控制 group-delay peak 的强度和宽度。
- `theta`：控制 group-delay peak 的中心位置。

旧版程序的问题是，多个 `theta` 可以自由移动，优化过程中可能 collapse 到相同或相近位置。新版程序改成 ordered theta 参数化：optimizer 不再直接优化每个 section 的绝对 `theta` 位置，而是优化相邻 section 之间的间隔参数。程序根据这些间隔参数生成一组从低到高排列的 `theta`，并设置最小间隔，避免多个 section 挤在同一个频率位置。这样每个 section 更倾向于分布在不同频率区域，避免多个 section 重复拟合同一处 group-delay ripple。

当前 least-squares 的目标也更明确。程序先读取 L1-08 fixed FIR 之后的 group delay：

```text
original_delay_ns
```

然后取它相对均值的形状：

```text
original_shape_ns = original_delay_ns - mean(original_delay_ns)
```

all-pass 设计的目标不是拟合绝对 group delay，而是让 all-pass group-delay shape 近似抵消这个 ripple：

```text
allpass_shape_ns ≈ -original_shape_ns
```

所以 residual 可以理解为：

```text
residual = weight * (allpass_shape_ns + original_shape_ns)
```

最终：

```text
compensated_delay_ns = original_delay_ns + allpass_delay_ns
```

应该尽量接近一个常数延迟。程序使用 `scipy.optimize.least_squares` 做有界非线性最小二乘，`r` 被限制在稳定范围内，theta 通过 ordered gap 生成。优化后输出 float coefficient、all-pass response、metrics，再进入 fixed-point quantization。

在 fixed-point 侧，L1-09 当前使用 Q3.15 / 18-bit coefficient。由于 all-pass 分子和分母有对称关系，RTL 实际只需要存 `a1` 和 `a2`：

```text
a1 = -2r cos(theta)
a2 = r^2
```

对应分子可以在 RTL 内部恢复：

```text
b0 = a2
b1 = a1
b2 = 1.0
```

这减少了 coefficient storage，也让 RTL 和数学模型更一致。

## 4. Plan B 评估

Plan B 的核心想法可以理解成：H1 是一个已经测出来的失真通道，它会同时改变信号的幅度和相位；我们希望再放一个 digital filter 在后面，让两者串起来以后接近一个理想系统。

如果 H1 在某个频率把信号放大了，补偿器就应该在这个频率压低一点；如果 H1 在某个频率把信号压低了，补偿器就应该抬高一点。相位也是同理：如果 H1 造成了额外相位弯曲，补偿器就产生相反的相位弯曲。这样 H1 和补偿器相乘后，整体 response 就更接近平坦幅度和线性相位。

Base Plan 把这个任务拆成两部分：L1-08 用 real FIR 主要处理 magnitude，L1-09 用 all-pass IIR 主要处理 phase/group delay。Plan B 则更直接：用一个 complex FIR 同时处理 magnitude 和 phase。因为 complex FIR 的 coefficient 有 real 和 imaginary 两部分，所以它天然可以同时改变幅度和相位，不像 real FIR 那样主要适合做线性相位的幅度补偿。

从频域看，Plan B 想让下面这个关系成立：

```text
H1(f) * FIR(f) ≈ ideal_delay(f)
```

也就是说，H1 经过 Plan B FIR 之后，最好只剩一个固定延迟，不再有明显 magnitude ripple 或 group-delay ripple。把上式移项，就得到 FIR 的目标响应：

```text
FIR_target(f) = exp(-j w D) / H1(f)
```

这里 `exp(-j w D)` 就是 ideal delay，也就是一个纯延迟系统。它不会改变幅度，只会让所有频率按照同一个 delay 线性旋转相位。加入这个参考延迟的原因是：真实 FIR 是因果系统，不能凭空提前输出未来的 sample。如果直接设计 `1/H1(f)`，目标相位可能要求系统“提前”，这对实时硬件不合理；加上一个合适的 delay 后，目标更容易由 FIR 实现。

Plan B 的优点很明显：它不需要把 magnitude 和 group delay 分开处理，一个 complex FIR 就能同时补偿二者。从 sweep 观察看，Plan B 的补偿效果是有竞争力的，尤其在较多 taps 的情况下，magnitude ripple 和 phase/group-delay error 都可以压得更低。

但是 Plan B 的硬件代价也明显更高。complex FIR 每个 tap 都需要 complex multiply-accumulate。一个 complex multiplication 通常可以估算为 4 个 real multipliers。以当前 Plan B 常见设置为例：

- 256-tap complex FIR 约等于 1024 个 real multipliers。
- 320-tap complex FIR 约等于 1280 个 real multipliers。

此外，Plan B 还需要 real/imag 两套 coefficient memory，更宽的 complex adder tree，以及更高的 routing 和 timing pressure。相比之下，Base Plan 的 L1-08 是 real FIR，L1-09 是 all-pass IIR section cascade；L1-09 每个 section 只存两个参数 `a1/a2`。因此从 RTL 落地和资源效率角度，当前更适合继续推进 Base Plan。

所以当前判断是：Plan B 可以作为 high-performance candidate 或 architecture comparison 保留，但不作为当前 RTL 主线。它的价值在于给出一个性能上限参考，并帮助评估 Base Plan 的资源/性能折中是否合理。

## 5. 当前 RTL 架构

当前 RTL 设计文件位于 repo 的 `RTL_design` folder。RTL 采用 Base Plan 架构，顶层模块是 `base_plan_top`，数据路径是：

```text
i_in/q_in -> L1-08 -> L1-09 -> o_i/o_q
```

顶层输入输出包括：

- `clk`：系统时钟。
- `reset_n`：低有效 reset。
- `i_in`, `q_in`：输入 I/Q sample。
- `in_valid`：输入 sample 有效。
- `l1_08_bypass`：跳过 L1-08。
- `l1_09_bypass`：跳过 L1-09。
- `o_i`, `o_q`：输出 I/Q sample。
- `o_valid`：输出 sample 有效。

### L1-08

L1-08 是 80-tap real FIR。I/Q 两路各有一条 sample shift register，但共用同一组 real coefficients。coefficients 在 reset 时从 generated `.svh` preload 到 register bank，之后保持不变。

L1-08 的核心结构包括：

- 系数寄存器组。
- I/Q 采样移位寄存器。
- 并行乘法器阵列。
- 流水线加法树。
- 舍入/饱和处理。
- valid 对齐流水线。

当前 FIR MAC 使用 pipelined adder tree。对于 80 taps，adder tree depth 是 7 cycles。由于 shift register 在 clock edge 后才更新，valid alignment 额外考虑了一拍 sample window 对齐，因此当前 L1-08 的 output latency 用 `OUTPUT_LATENCY = MAC_LATENCY + 1` 对齐。

L1-08 的 `run_valid` 定义为：

```text
run_valid = in_valid && coeffs_ready
```

当 `run_valid=0` 时，sample shift register 和 valid pipe 都暂停推进。这样可以处理非连续 `in_valid`，避免 data pipeline 停住但 valid pipeline 继续前进造成错位。

### L1-09

L1-09 是 64-section second-order all-pass IIR cascade。I/Q 两路各有一条 second-order section cascade，也就是由多个二阶滤波器 section 串联起来的结构，并且两路共用同一组 all-pass coefficients。当前 RTL 只存每个 section 的 `a1/a2`，不再存重复的 `b0/b1/b2`。

每个二阶滤波器 section 的计算形式是：

```text
y[n] = a2*x[n] + a1*x[n-1] + 1.0*x[n-2]
       - a1*y[n-1] - a2*y[n-2]
```

其中：

```text
b0 = a2
b1 = a1
b2 = 1.0
```

RTL 中 `b2=1.0` 通过 fixed-point shift 实现，不需要额外 coefficient storage。

当前 L1-09 section 之间是 combinational connection：

```text
stage_out[sec-1] -> stage_in[sec]
```

每个二阶滤波器 section 自己有一个 registered `y_out`。因此 64 sections 的 IIR latency 是 64 cycles。valid pipe 使用 `IIR_LATENCY = SECTION_COUNT` 对齐，并且和 data pipeline 一样只在 `run_valid` 时前进。

L1-09 也支持 bypass。bypass 为 1 时，当前输入 sample 直接输出；bypass 为 0 时，输出经过 all-pass cascade 的 filtered sample。
