# L1-08 Sweep Test

This folder contains the parameter sweep wrapper for the existing `L1-08_sim` pipeline.

It sweeps:

```text
tap_num
regularization
coeff_frac_bits / fixed-point format
```

It does not sweep seed. The current seeds are read from:

```text
../L1_08_experiment_config.json
```

## Dry Run

Use dry-run first to inspect all combinations without running simulations:

```powershell
python sweep_test\run_sweep.py --dry-run
```

## Full Sweep

```powershell
python sweep_test\run_sweep.py
```

Output goes to:

```text
../sweep_result/<current_seed_label>/<combo_folder>/
```

After each combo is copied into `sweep_result`, the temporary run folder under
`../L1-08_sim/data` and `../L1-08_sim/results` is removed when
`cleanup_sim_outputs_after_copy` is enabled in `config.json`.

Each combo folder contains:

```text
data/   # copied CSV and run_summary.json files
graph/  # copied PNG plots
logs/   # stdout/stderr from each existing pipeline script
combo_metadata.json
```

The sweep folder also gets:

```text
sweep_summary.csv
```
