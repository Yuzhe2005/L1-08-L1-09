# RTL Design V2 - L1-08

This folder is the staged RTL structure for L1-08 mode expansion.

Current implementation:

- `L1_08_MODE_SINGLE`: implemented by `l1_08_v2_core_single`.
- `L1_08_MODE_PARALLEL`: implemented by `l1_08_v2_core_parallel`.
- `L1_08_MODE_BUFFERED`: reserved, currently reports unsupported.

Compile order:

1. `base_plan_l1_08_v2_pkg.sv`
2. `L1-08_single.sv`
3. `L1-08_parallel.sv`
4. `top.sv`

Top module:

- `l1_08_v2_top`

Behavior:

- In single mode, one valid clock consumes one IQ sample.
- In parallel mode, one valid clock consumes `parallel_active_lanes` IQ samples, from 0 up to `PARALLEL_FACTOR`. `parallel_x_i[0]` and `parallel_x_q[0]` are the oldest samples in the bundle; `parallel_x_i[parallel_active_lanes-1]` and `parallel_x_q[parallel_active_lanes-1]` are the newest valid samples.
- In unsupported modes, `mode_supported` is low, `mode_error` is high when `in_valid` is asserted, and output valid remains low.
- When leaving single mode, the top-level selector synchronously clears the single core state so stale pipeline data cannot be emitted after a later mode switch.
- When leaving parallel mode, the top-level selector synchronously clears the parallel core state for the same reason.
- If `parallel_active_lanes > PARALLEL_FACTOR`, the parallel core does not consume the input bundle and the top-level `mode_error` is asserted.
