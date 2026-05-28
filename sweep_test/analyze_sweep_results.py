import argparse
import csv
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import matplotlib.pyplot as plt
import numpy as np

from sweep_config import SweepSettings


DEFAULT_CONFIG = Path(__file__).resolve().parent / "config.json"
DEFAULT_TARGET_RIPPLE_DB = 0.1


@dataclass(frozen=True)
class SweepRow:
    combo_folder: str
    tap_num: int
    regularization: float
    coeff_total_bits: int
    coeff_frac_bits: int
    fixed_format: str
    run_name: str
    h1_ripple_db: float
    float_dense_ripple_db: float
    float_dense_pass_0p1db: bool
    max_abs_coeff: float
    fixed_saturation_count: int
    fixed_dense_ripple_db: float
    fixed_dense_pass_0p1db: bool
    behavior_float_ripple_db: float
    behavior_fixed_ripple_db: float
    behavior_fixed_pass_0p1db: bool
    qam_float_magnitude_only_evm_percent: float
    qam_fixed_magnitude_only_evm_percent: float

    @property
    def is_saturated(self) -> bool:
        return self.fixed_saturation_count > 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Analyze an L1-08 sweep_summary.csv file.")
    parser.add_argument(
        "--config",
        type=Path,
        default=DEFAULT_CONFIG,
        help=f"Sweep config JSON. Default: {DEFAULT_CONFIG}",
    )
    parser.add_argument(
        "--summary-csv",
        type=Path,
        default=None,
        help="Explicit sweep_summary.csv path. Default: current sweep output folder from config.",
    )
    parser.add_argument(
        "--target-ripple-db",
        type=float,
        default=DEFAULT_TARGET_RIPPLE_DB,
        help=f"Pass/fail ripple target for report text. Default: {DEFAULT_TARGET_RIPPLE_DB} dB.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    settings = SweepSettings.from_json(args.config)
    summary_csv = args.summary_csv or settings.sweep_output_dir() / "sweep_summary.csv"
    summary_csv = summary_csv.resolve()
    if not summary_csv.is_file():
        raise FileNotFoundError(f"sweep_summary.csv not found: {summary_csv}")

    output_dir = summary_csv.parent
    rows = load_summary(summary_csv)
    analysis = analyze_rows(rows)

    best_csv = output_dir / "sweep_best_combos.csv"
    group_csv = output_dir / "sweep_group_summary.csv"
    report_md = output_dir / "sweep_analysis_report.md"

    write_best_combos_csv(analysis, best_csv)
    write_group_summary_csv(rows, group_csv)
    plot_paths = write_plots(rows, output_dir, args.target_ripple_db)
    write_report(rows, analysis, report_md, best_csv, group_csv, plot_paths, args.target_ripple_db)

    print(f"summary_csv: {summary_csv}")
    print(f"report_md: {report_md}")
    print(f"best_combos_csv: {best_csv}")
    print(f"group_summary_csv: {group_csv}")
    print("plots:")
    for path in plot_paths:
        print(f"  {path}")


def load_summary(summary_csv: Path) -> list[SweepRow]:
    with summary_csv.open("r", newline="", encoding="utf-8") as csv_file:
        reader = csv.DictReader(csv_file)
        required = set(SweepRow.__dataclass_fields__)
        if not reader.fieldnames or not required.issubset(reader.fieldnames):
            missing = sorted(required - set(reader.fieldnames or []))
            raise ValueError(f"{summary_csv} is missing columns: {missing}")

        rows = []
        for item in reader:
            rows.append(
                SweepRow(
                    combo_folder=item["combo_folder"],
                    tap_num=int(item["tap_num"]),
                    regularization=float(item["regularization"]),
                    coeff_total_bits=int(item["coeff_total_bits"]),
                    coeff_frac_bits=int(item["coeff_frac_bits"]),
                    fixed_format=item["fixed_format"],
                    run_name=item["run_name"],
                    h1_ripple_db=float(item["h1_ripple_db"]),
                    float_dense_ripple_db=float(item["float_dense_ripple_db"]),
                    float_dense_pass_0p1db=parse_bool(item["float_dense_pass_0p1db"]),
                    max_abs_coeff=float(item["max_abs_coeff"]),
                    fixed_saturation_count=int(item["fixed_saturation_count"]),
                    fixed_dense_ripple_db=float(item["fixed_dense_ripple_db"]),
                    fixed_dense_pass_0p1db=parse_bool(item["fixed_dense_pass_0p1db"]),
                    behavior_float_ripple_db=float(item["behavior_float_ripple_db"]),
                    behavior_fixed_ripple_db=float(item["behavior_fixed_ripple_db"]),
                    behavior_fixed_pass_0p1db=parse_bool(item["behavior_fixed_pass_0p1db"]),
                    qam_float_magnitude_only_evm_percent=float(item["qam_float_magnitude_only_evm_percent"]),
                    qam_fixed_magnitude_only_evm_percent=float(item["qam_fixed_magnitude_only_evm_percent"]),
                )
            )

    if not rows:
        raise ValueError(f"{summary_csv} has no data rows.")
    return rows


def parse_bool(value: str) -> bool:
    lowered = value.strip().lower()
    if lowered in {"true", "1", "yes"}:
        return True
    if lowered in {"false", "0", "no"}:
        return False
    raise ValueError(f"Cannot parse bool value: {value!r}")


def analyze_rows(rows: list[SweepRow]) -> dict[str, SweepRow]:
    unsaturated = [row for row in rows if not row.is_saturated]
    pass_fixed_dense = [row for row in rows if row.fixed_dense_pass_0p1db and not row.is_saturated]
    pass_behavior = [row for row in rows if row.behavior_fixed_pass_0p1db and not row.is_saturated]

    candidates_for_balanced = pass_fixed_dense or unsaturated or rows
    return {
        "best_fixed_dense": min(rows, key=lambda row: row.fixed_dense_ripple_db),
        "best_fixed_dense_unsaturated": min(unsaturated or rows, key=lambda row: row.fixed_dense_ripple_db),
        "best_behavior_fixed": min(rows, key=lambda row: row.behavior_fixed_ripple_db),
        "best_behavior_fixed_unsaturated": min(unsaturated or rows, key=lambda row: row.behavior_fixed_ripple_db),
        "best_qam_fixed": min(rows, key=lambda row: row.qam_fixed_magnitude_only_evm_percent),
        "best_qam_fixed_unsaturated": min(
            unsaturated or rows,
            key=lambda row: row.qam_fixed_magnitude_only_evm_percent,
        ),
        "lowest_tap_dense_pass": min(candidates_for_balanced, key=lambda row: (row.tap_num, row.fixed_dense_ripple_db)),
        "lowest_tap_behavior_pass": min(pass_behavior or candidates_for_balanced, key=lambda row: (row.tap_num, row.behavior_fixed_ripple_db)),
    }


def write_best_combos_csv(analysis: dict[str, SweepRow], output_csv: Path) -> None:
    fieldnames = [
        "criterion",
        "combo_folder",
        "tap_num",
        "regularization",
        "fixed_format",
        "fixed_saturation_count",
        "fixed_dense_ripple_db",
        "behavior_fixed_ripple_db",
        "qam_fixed_magnitude_only_evm_percent",
        "max_abs_coeff",
    ]
    with output_csv.open("w", newline="", encoding="utf-8") as csv_file:
        writer = csv.DictWriter(csv_file, fieldnames=fieldnames)
        writer.writeheader()
        for criterion, row in analysis.items():
            writer.writerow(row_to_best_dict(criterion, row))


def row_to_best_dict(criterion: str, row: SweepRow) -> dict[str, Any]:
    return {
        "criterion": criterion,
        "combo_folder": row.combo_folder,
        "tap_num": row.tap_num,
        "regularization": f"{row.regularization:.12g}",
        "fixed_format": row.fixed_format,
        "fixed_saturation_count": row.fixed_saturation_count,
        "fixed_dense_ripple_db": f"{row.fixed_dense_ripple_db:.9f}",
        "behavior_fixed_ripple_db": f"{row.behavior_fixed_ripple_db:.9f}",
        "qam_fixed_magnitude_only_evm_percent": f"{row.qam_fixed_magnitude_only_evm_percent:.9f}",
        "max_abs_coeff": f"{row.max_abs_coeff:.9f}",
    }


def write_group_summary_csv(rows: list[SweepRow], output_csv: Path) -> None:
    fieldnames = [
        "group_type",
        "group_value",
        "combo_count",
        "fixed_dense_pass_count",
        "behavior_fixed_pass_count",
        "saturated_combo_count",
        "best_fixed_dense_ripple_db",
        "best_behavior_fixed_ripple_db",
        "best_qam_fixed_magnitude_only_evm_percent",
        "mean_fixed_dense_ripple_db",
        "mean_behavior_fixed_ripple_db",
        "mean_qam_fixed_magnitude_only_evm_percent",
    ]

    grouped: list[tuple[str, str, list[SweepRow]]] = []
    for group_type, key_fn in [
        ("tap_num", lambda row: str(row.tap_num)),
        ("regularization", lambda row: f"{row.regularization:.12g}"),
        ("fixed_format", lambda row: row.fixed_format),
    ]:
        buckets: dict[str, list[SweepRow]] = defaultdict(list)
        for row in rows:
            buckets[key_fn(row)].append(row)
        for group_value in sorted(buckets, key=sort_group_key):
            grouped.append((group_type, group_value, buckets[group_value]))

    with output_csv.open("w", newline="", encoding="utf-8") as csv_file:
        writer = csv.DictWriter(csv_file, fieldnames=fieldnames)
        writer.writeheader()
        for group_type, group_value, bucket in grouped:
            writer.writerow(group_summary_row(group_type, group_value, bucket))


def sort_group_key(value: str) -> tuple[int, float | str]:
    try:
        return (0, float(value))
    except ValueError:
        return (1, value)


def group_summary_row(group_type: str, group_value: str, rows: list[SweepRow]) -> dict[str, Any]:
    return {
        "group_type": group_type,
        "group_value": group_value,
        "combo_count": len(rows),
        "fixed_dense_pass_count": sum(row.fixed_dense_pass_0p1db for row in rows),
        "behavior_fixed_pass_count": sum(row.behavior_fixed_pass_0p1db for row in rows),
        "saturated_combo_count": sum(row.is_saturated for row in rows),
        "best_fixed_dense_ripple_db": f"{min(row.fixed_dense_ripple_db for row in rows):.9f}",
        "best_behavior_fixed_ripple_db": f"{min(row.behavior_fixed_ripple_db for row in rows):.9f}",
        "best_qam_fixed_magnitude_only_evm_percent": f"{min(row.qam_fixed_magnitude_only_evm_percent for row in rows):.9f}",
        "mean_fixed_dense_ripple_db": f"{mean(row.fixed_dense_ripple_db for row in rows):.9f}",
        "mean_behavior_fixed_ripple_db": f"{mean(row.behavior_fixed_ripple_db for row in rows):.9f}",
        "mean_qam_fixed_magnitude_only_evm_percent": f"{mean(row.qam_fixed_magnitude_only_evm_percent for row in rows):.9f}",
    }


def mean(values: Any) -> float:
    values = list(values)
    return float(sum(values) / len(values))


def write_plots(rows: list[SweepRow], output_dir: Path, target_ripple_db: float) -> list[Path]:
    plot_paths = [
        output_dir / "sweep_fixed_dense_ripple_by_tap.png",
        output_dir / "sweep_behavior_ripple_by_tap.png",
        output_dir / "sweep_qam_evm_by_tap.png",
        output_dir / "sweep_saturation_and_coeff_range.png",
    ]

    plot_metric_by_tap(
        rows,
        metric_name="fixed_dense_ripple_db",
        ylabel="Fixed dense ripple (dB)",
        title="L1-08 sweep fixed-point dense ripple",
        output_path=plot_paths[0],
        target_line=target_ripple_db,
    )
    plot_metric_by_tap(
        rows,
        metric_name="behavior_fixed_ripple_db",
        ylabel="Fixed multi-tone ripple (dB)",
        title="L1-08 sweep fixed-point behavior ripple",
        output_path=plot_paths[1],
        target_line=target_ripple_db,
    )
    plot_metric_by_tap(
        rows,
        metric_name="qam_fixed_magnitude_only_evm_percent",
        ylabel="QAM magnitude-only EVM (%)",
        title="L1-08 sweep QAM magnitude-only EVM",
        output_path=plot_paths[2],
        target_line=None,
    )
    plot_coeff_and_saturation(rows, plot_paths[3])

    return plot_paths


def plot_metric_by_tap(
    rows: list[SweepRow],
    metric_name: str,
    ylabel: str,
    title: str,
    output_path: Path,
    target_line: float | None,
) -> None:
    fig, ax = plt.subplots(figsize=(11, 6))
    formats = sorted({row.fixed_format for row in rows}, key=fixed_format_sort_key)
    markers = ["o", "s", "^", "D", "v"]

    for idx, fixed_format in enumerate(formats):
        subset = [row for row in rows if row.fixed_format == fixed_format]
        x = [row.tap_num + regularization_offset(row.regularization) for row in subset]
        y = [getattr(row, metric_name) for row in subset]
        colors = [regularization_color(row.regularization) for row in subset]
        ax.scatter(
            x,
            y,
            label=fixed_format,
            marker=markers[idx % len(markers)],
            s=70,
            c=colors,
            edgecolors="black",
            linewidths=0.5,
        )

    if target_line is not None:
        ax.axhline(target_line, color="black", linestyle="--", linewidth=1.2, label=f"{target_line:g} dB target")

    ax.set_title(title)
    ax.set_xlabel("tap_num, horizontally offset by regularization")
    ax.set_ylabel(ylabel)
    ax.grid(True, alpha=0.3)
    ax.legend(loc="best")
    add_regularization_note(ax)
    fig.tight_layout()
    fig.savefig(output_path, dpi=160)
    plt.close(fig)


def regularization_offset(regularization: float) -> float:
    known = sorted({1e-4, 3e-4, 1e-3})
    if regularization in known:
        return {-1: -0.9, 0: 0.0, 1: 0.9}[known.index(regularization) - 1]
    return 0.0


def regularization_color(regularization: float) -> str:
    labels = {
        1e-4: "#1f77b4",
        3e-4: "#ff7f0e",
        1e-3: "#2ca02c",
    }
    return labels.get(regularization, "#7f7f7f")


def fixed_format_sort_key(value: str) -> tuple[int, str]:
    if value.startswith("Q") and "." in value:
        left, right = value[1:].split(".", 1)
        if left.isdigit() and right.isdigit():
            return (int(left), right)
    return (999, value)


def add_regularization_note(ax: Any) -> None:
    ax.text(
        0.01,
        0.02,
        "color: blue=1e-4, orange=3e-4, green=1e-3",
        transform=ax.transAxes,
        fontsize=9,
        verticalalignment="bottom",
        bbox={"boxstyle": "round,pad=0.25", "facecolor": "white", "alpha": 0.8, "edgecolor": "0.8"},
    )


def plot_coeff_and_saturation(rows: list[SweepRow], output_path: Path) -> None:
    fig, axes = plt.subplots(2, 1, figsize=(11, 8), sharex=True)
    sorted_rows = sorted(rows, key=lambda row: (row.tap_num, row.regularization, fixed_format_sort_key(row.fixed_format)))
    labels = [row.combo_folder for row in sorted_rows]
    x = np.arange(len(sorted_rows))

    axes[0].bar(x, [row.max_abs_coeff for row in sorted_rows], color="#4c78a8")
    axes[0].set_ylabel("max |coeff|")
    axes[0].set_title("Coefficient scale and saturation count")
    axes[0].grid(True, axis="y", alpha=0.3)

    axes[1].bar(x, [row.fixed_saturation_count for row in sorted_rows], color="#e45756")
    axes[1].set_ylabel("saturated coeff count")
    axes[1].set_xlabel("combo")
    axes[1].set_xticks(x)
    axes[1].set_xticklabels(labels, rotation=90, fontsize=8)
    axes[1].grid(True, axis="y", alpha=0.3)

    fig.tight_layout()
    fig.savefig(output_path, dpi=160)
    plt.close(fig)


def write_report(
    rows: list[SweepRow],
    analysis: dict[str, SweepRow],
    output_md: Path,
    best_csv: Path,
    group_csv: Path,
    plot_paths: list[Path],
    target_ripple_db: float,
) -> None:
    taps = sorted({row.tap_num for row in rows})
    regs = sorted({row.regularization for row in rows})
    formats = sorted({row.fixed_format for row in rows}, key=fixed_format_sort_key)
    saturated = [row for row in rows if row.is_saturated]

    lines: list[str] = []
    lines.append("# L1-08 Sweep Analysis Report")
    lines.append("")
    lines.append("## 1. Scope")
    lines.append("")
    lines.append("This report summarizes one completed L1-08 parameter sweep from `sweep_summary.csv`.")
    lines.append("")
    lines.append(f"- Total combos: `{len(rows)}`")
    lines.append(f"- tap_num values: `{', '.join(str(item) for item in taps)}`")
    lines.append(f"- regularization values: `{', '.join(f'{item:.12g}' for item in regs)}`")
    lines.append(f"- fixed-point formats: `{', '.join(formats)}`")
    lines.append(f"- H1 ripple before compensation: `{rows[0].h1_ripple_db:.6f} dB`")
    lines.append(f"- Ripple pass target used in this report: `{target_ripple_db:.6f} dB`")
    lines.append("")

    lines.append("## 2. Overall Result")
    lines.append("")
    lines.append(f"- Fixed dense ripple pass count: `{sum(row.fixed_dense_pass_0p1db for row in rows)} / {len(rows)}`")
    lines.append(f"- Fixed multi-tone behavior pass count: `{sum(row.behavior_fixed_pass_0p1db for row in rows)} / {len(rows)}`")
    lines.append(f"- Saturated combo count: `{len(saturated)} / {len(rows)}`")
    lines.append("")
    if saturated:
        lines.append("Saturated combos:")
        lines.append("")
        for row in saturated:
            lines.append(
                f"- `{row.combo_folder}`: saturation_count={row.fixed_saturation_count}, "
                f"max_abs_coeff={row.max_abs_coeff:.6f}, fixed_dense_ripple={row.fixed_dense_ripple_db:.6f} dB"
            )
        lines.append("")

    lines.append("## 3. Best Combos")
    lines.append("")
    lines.append("| Criterion | Combo | Dense ripple (dB) | Behavior ripple (dB) | QAM mag-only EVM (%) | Saturation |")
    lines.append("|---|---|---:|---:|---:|---:|")
    for criterion, row in analysis.items():
        lines.append(
            f"| {criterion} | `{row.combo_folder}` | {row.fixed_dense_ripple_db:.6f} | "
            f"{row.behavior_fixed_ripple_db:.6f} | {row.qam_fixed_magnitude_only_evm_percent:.6f} | "
            f"{row.fixed_saturation_count} |"
        )
    lines.append("")

    lines.append("## 4. Group Summary")
    lines.append("")
    lines.append("### By Tap")
    lines.append("")
    append_group_table(lines, rows, "tap_num", lambda row: str(row.tap_num))
    lines.append("")
    lines.append("### By Regularization")
    lines.append("")
    append_group_table(lines, rows, "regularization", lambda row: f"{row.regularization:.12g}")
    lines.append("")
    lines.append("### By Fixed-Point Format")
    lines.append("")
    append_group_table(lines, rows, "fixed_format", lambda row: row.fixed_format)
    lines.append("")

    lines.append("## 5. Interpretation")
    lines.append("")
    lines.extend(interpretation_lines(rows, analysis, target_ripple_db))
    lines.append("")

    lines.append("## 6. Generated Files")
    lines.append("")
    lines.append(f"- Best combo table: `{best_csv.name}`")
    lines.append(f"- Group summary table: `{group_csv.name}`")
    for path in plot_paths:
        lines.append(f"- Plot: `{path.name}`")
    lines.append("")

    lines.append("## 7. Plots")
    lines.append("")
    for path in plot_paths:
        lines.append(f"![{path.stem}]({path.name})")
        lines.append("")

    output_md.write_text("\n".join(lines), encoding="utf-8")


def append_group_table(lines: list[str], rows: list[SweepRow], group_name: str, key_fn: Any) -> None:
    buckets: dict[str, list[SweepRow]] = defaultdict(list)
    for row in rows:
        buckets[key_fn(row)].append(row)

    lines.append(
        "| Group | Combos | Dense pass | Behavior pass | Saturated | "
        "Best dense (dB) | Best behavior (dB) | Best QAM mag EVM (%) |"
    )
    lines.append("|---|---:|---:|---:|---:|---:|---:|---:|")
    for key in sorted(buckets, key=sort_group_key):
        bucket = buckets[key]
        lines.append(
            f"| {key} | {len(bucket)} | {sum(row.fixed_dense_pass_0p1db for row in bucket)} | "
            f"{sum(row.behavior_fixed_pass_0p1db for row in bucket)} | {sum(row.is_saturated for row in bucket)} | "
            f"{min(row.fixed_dense_ripple_db for row in bucket):.6f} | "
            f"{min(row.behavior_fixed_ripple_db for row in bucket):.6f} | "
            f"{min(row.qam_fixed_magnitude_only_evm_percent for row in bucket):.6f} |"
        )


def interpretation_lines(rows: list[SweepRow], analysis: dict[str, SweepRow], target_ripple_db: float) -> list[str]:
    lines: list[str] = []
    by_tap: dict[int, list[SweepRow]] = defaultdict(list)
    for row in rows:
        by_tap[row.tap_num].append(row)

    weak_taps = [
        tap
        for tap, bucket in by_tap.items()
        if sum(row.fixed_dense_pass_0p1db for row in bucket) == 0
    ]
    strong_taps = [
        tap
        for tap, bucket in by_tap.items()
        if sum(row.fixed_dense_pass_0p1db for row in bucket) == len(bucket)
    ]

    if weak_taps:
        lines.append(
            f"- tap_num `{', '.join(str(item) for item in sorted(weak_taps))}` did not pass dense "
            f"`{target_ripple_db:g} dB` in this sweep. It is not a robust choice for this H1 seed."
        )
    if strong_taps:
        lines.append(
            f"- tap_num `{', '.join(str(item) for item in sorted(strong_taps))}` passed dense "
            f"`{target_ripple_db:g} dB` for every swept regularization/fixed-point format."
        )

    balanced = analysis["lowest_tap_dense_pass"]
    performance = analysis["best_qam_fixed_unsaturated"]
    lines.append(
        f"- Lowest-tap dense-pass candidate: `{balanced.combo_folder}` "
        f"with fixed dense ripple `{balanced.fixed_dense_ripple_db:.6f} dB` and QAM magnitude-only EVM "
        f"`{balanced.qam_fixed_magnitude_only_evm_percent:.6f}%`."
    )
    lines.append(
        f"- Best unsaturated QAM magnitude-only EVM candidate: `{performance.combo_folder}` "
        f"with `{performance.qam_fixed_magnitude_only_evm_percent:.6f}%`."
    )

    saturated = [row for row in rows if row.is_saturated]
    if saturated:
        worst = max(saturated, key=lambda row: row.fixed_dense_ripple_db)
        lines.append(
            f"- Saturation is a hard failure mode: `{worst.combo_folder}` reaches "
            f"`{worst.fixed_dense_ripple_db:.6f} dB` fixed dense ripple after coefficient clipping."
        )

    lines.append(
        "- Dense ripple should be treated as the stricter pass/fail metric because multi-tone verification samples "
        "only selected frequencies and may miss the worst point in the full H1 grid."
    )
    return lines


if __name__ == "__main__":
    main()
