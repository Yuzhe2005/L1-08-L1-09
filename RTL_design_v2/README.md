# RTL Design V2 - L1-08

This folder is the staged RTL structure for L1-08 mode expansion.

Current implementation:

- `L1_08_MODE_SINGLE`: implemented by `l1_08_v2_core_single`.
- `L1_08_MODE_PARALLEL`: implemented by `l1_08_v2_core_parallel`.
- `L1_08_MODE_BUFFERED`: implemented by `l1_08_v2_input_buffer` feeding `l1_08_v2_core_parallel`.

Compile order:

1. `l1_08_v2_pkg.sv`
2. `l1_08_single_core.sv`
3. `l1_08_input_buffer.sv`
4. `l1_08_parallel_core.sv`
5. `l1_08_top.sv`

Top module:

- `l1_08_v2_top`

Behavior:

- In single mode, one valid clock consumes one IQ sample.
- In parallel mode, one valid clock consumes `parallel_active_lanes` IQ samples, from 0 up to `PARALLEL_FACTOR`. `parallel_x_i[0]` and `parallel_x_q[0]` are the oldest samples in the bundle; `parallel_x_i[parallel_active_lanes-1]` and `parallel_x_q[parallel_active_lanes-1]` are the newest valid samples.
- In buffered mode, `sample_clk` is the FIFO write clock and `clk` is the FIFO read/core clock. `x_i/q` is the upstream write-side sample, accepted at up to one IQ sample per `sample_clk`.
- The input buffer first packs `PARALLEL_FACTOR` accepted IQ samples in the `sample_clk` domain, then writes that full bundle as one word into an async FIFO. The `clk` read side emits one chronological bundle per FIFO read when the parallel core asserts ready.
- The buffered path emits a bundle only after at least `PARALLEL_FACTOR` samples are queued. Tail flushing for fewer than `PARALLEL_FACTOR` remaining samples is not implemented yet.
- Sustained operation requires `PARALLEL_FACTOR * clk_rate >= sample_clk_rate`; otherwise the FIFO will eventually overflow.
- `BUFFER_DEPTH` is expected to be a power of two for the async FIFO pointer wrap.
- `input_ready` tells the upstream side whether the selected mode can accept the current input. In buffered mode it is the buffer write-side ready; in parallel mode it is the parallel core ready; in single mode it follows coefficient readiness.
- In unsupported modes, `mode_supported` is low, `mode_error` is high when `in_valid` is asserted, and output valid remains low.
- When leaving single mode, the top-level selector synchronously clears the single core state so stale pipeline data cannot be emitted after a later mode switch.
- When leaving both parallel and buffered mode, the top-level selector synchronously clears the shared parallel compute core state for the same reason.
- When leaving buffered mode, the input buffer is synchronously cleared.
- If `parallel_active_lanes > PARALLEL_FACTOR`, the parallel core does not consume the input bundle and the top-level `mode_error` is asserted.
- In buffered mode, `buffer_overflow_error` exposes input-side overflow.
