import argparse
import csv
import os
import tempfile
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from scipy.optimize import least_squares

import l1_09_bootstrap  # noqa: F401
from shared_sim.config import get_common_config_value
from shared_sim.paths import DATA_ROOT, RESULTS_ROOT as GRAPH_ROOT

L1_09_ROOT = Path(__file__).resolve().parent
MPLCONFIG_ROOT = Path(tempfile.gettempdir()) / "rigol_l1_09_fix_matplotlib" / f"pid_{os.getpid()}"

MPLCONFIG_ROOT.mkdir(parents=True, exist_ok=True)
os.environ.setdefault("MPLCONFIGDIR", str(MPLCONFIG_ROOT))

import matplotlib

matplotlib.use("Agg")

import matplotlib.pyplot as plt
from shared_sim.config import get_l1_09_config_value


@dataclass(frozen=True)
class GroupDelayInput:
    input_csv: Path
    run_name: str
    freq_hz: np.ndarray
    omega_rad: np.ndarray
    phase_rad: np.ndarray
    group_delay_ns: np.ndarray


@dataclass(frozen=True)
class AllPassDesign:
    input_data: GroupDelayInput
    output_dir: Path
    fs_hz: float
    section_count: int
    target_delay_ns: float
    margin_ns: float
    r_values: np.ndarray
    theta_values_rad: np.ndarray
    center_freq_hz: np.ndarray
    allpass_phase_rad: np.ndarray
    allpass_group_delay_ns: np.ndarray
    compensated_phase_rad: np.ndarray
    compensated_group_delay_ns: np.ndarray
    compensated_ripple_pp_ns: float
    compensated_rms_error_ns: float
    compensated_ripple_pp_max_ns: float
    meets_compensated_ripple_target: bool
    optimizer_cost: float
    optimizer_success: bool
    optimizer_message: str


def find_latest_group_delay_csv(data_root: Path = DATA_ROOT) -> Path:
    candidates = sorted(
        data_root.glob("base_plan_pipeline_data_*/l1_09_fix_group_delay/group_delay_analysis.csv"),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    if not candidates:
        raise FileNotFoundError(
            f"No group_delay_analysis.csv found under {data_root}. "
            "Run L1_09_sim/L1_09_group_delay_analyzer.py first."
        )
    return candidates[0]


def load_group_delay_csv(input_csv: Path) -> GroupDelayInput:
    freq_hz: list[float] = []
    omega_rad: list[float] = []
    phase_rad: list[float] = []
    group_delay_ns: list[float] = []

    with input_csv.open("r", newline="", encoding="utf-8") as csv_file:
        reader = csv.DictReader(csv_file)
        required_columns = {"freq_hz", "omega_rad", "phase_unwrapped_rad", "group_delay_ns"}
        if not reader.fieldnames or not required_columns.issubset(reader.fieldnames):
            raise ValueError(f"{input_csv} must contain columns: {sorted(required_columns)}")

        for row in reader:
            freq_hz.append(float(row["freq_hz"]))
            omega_rad.append(float(row["omega_rad"]))
            phase_rad.append(float(row["phase_unwrapped_rad"]))
            group_delay_ns.append(float(row["group_delay_ns"]))

    freq = np.asarray(freq_hz, dtype=float)
    omega = np.asarray(omega_rad, dtype=float)
    phase = np.asarray(phase_rad, dtype=float)
    delay = np.asarray(group_delay_ns, dtype=float)

    if freq.size < 16:
        raise ValueError("All-pass design needs at least 16 frequency points.")
    if not (freq.size == omega.size == phase.size == delay.size):
        raise ValueError("Input columns must have the same length.")
    if not np.all(np.isfinite(freq)) or not np.all(np.isfinite(omega)):
        raise ValueError("Frequency columns contain non-finite values.")
    if not np.all(np.isfinite(phase)) or not np.all(np.isfinite(delay)):
        raise ValueError("Phase or group delay columns contain non-finite values.")
    if not np.all(np.diff(freq) > 0):
        raise ValueError("freq_hz must be strictly increasing.")

    run_name = input_csv.parents[1].name if input_csv.parent.name == "l1_09_fix_group_delay" else input_csv.stem
    return GroupDelayInput(
        input_csv=input_csv,
        run_name=run_name,
        freq_hz=freq,
        omega_rad=omega,
        phase_rad=phase,
        group_delay_ns=delay,
    )


def default_output_dir(input_data: GroupDelayInput) -> Path:
    return DATA_ROOT / input_data.run_name / "l1_09_fix_allpass_iir_fs"


def default_graph_dir(input_data: GroupDelayInput) -> Path:
    return GRAPH_ROOT / input_data.run_name / "l1_09_fix_allpass_iir_fs"


def fs_based_digital_frequency(freq_hz: np.ndarray, fs_hz: float) -> np.ndarray:
    if fs_hz <= 0.0:
        raise ValueError("fs_hz must be positive.")
    if freq_hz[0] < 0.0:
        raise ValueError("This real-coefficient all-pass model expects non-negative frequencies.")
    nyquist_hz = 0.5 * fs_hz
    if freq_hz[-1] >= nyquist_hz:
        raise ValueError(
            "This real-coefficient all-pass model expects the design band below Nyquist. "
            f"f_max={freq_hz[-1]:.6g} Hz, Nyquist={nyquist_hz:.6g} Hz."
        )
    return 2.0 * np.pi * freq_hz / fs_hz


def second_order_allpass_response(
    digital_w_rad: np.ndarray,
    r_values: np.ndarray,
    theta_values_rad: np.ndarray,
) -> np.ndarray:
    z_inv = np.exp(-1j * digital_w_rad)
    response = np.ones_like(z_inv, dtype=complex)

    for r, theta in zip(r_values, theta_values_rad):
        c = np.cos(theta)
        numerator = (r * r) - (2.0 * r * c * z_inv) + (z_inv * z_inv)
        denominator = 1.0 - (2.0 * r * c * z_inv) + ((r * r) * z_inv * z_inv)
        response *= numerator / denominator

    return response


def response_phase_and_delay_ns(
    digital_w_rad: np.ndarray,
    omega_rad: np.ndarray,
    r_values: np.ndarray,
    theta_values_rad: np.ndarray,
) -> tuple[np.ndarray, np.ndarray]:
    response = second_order_allpass_response(digital_w_rad, r_values, theta_values_rad)
    phase_rad = np.unwrap(np.angle(response))
    delay_s = -np.gradient(phase_rad, omega_rad)
    return phase_rad, delay_s * 1e9


def theta_limits(digital_w_rad: np.ndarray) -> tuple[float, float]:
    band_low = float(digital_w_rad[0])
    band_high = float(digital_w_rad[-1])
    band_span = band_high - band_low
    theta_min = max(0.02 * np.pi, band_low - 0.2 * band_span)
    theta_max = min(0.98 * np.pi, band_high + 0.2 * band_span)
    return theta_min, theta_max


def ordered_thetas_from_gap_logits(
    gap_logits: np.ndarray,
    theta_min: float,
    theta_max: float,
    section_count: int,
) -> np.ndarray:
    if section_count == 1:
        return np.asarray([(theta_min + theta_max) * 0.5], dtype=float)
    if gap_logits.size != section_count - 1:
        raise ValueError("gap_logits must have length section_count - 1.")

    span = theta_max - theta_min
    gap_count = section_count - 1
    # Keep every adjacent section separated; softmax alone can still collapse gaps to zero.
    min_gap = span / (4.0 * section_count)
    reserved_span = min_gap * gap_count
    if reserved_span >= span:
        min_gap = 0.25 * span / gap_count
        reserved_span = min_gap * gap_count
    free_span = span - reserved_span

    weights = np.exp(gap_logits - np.max(gap_logits))
    extra_gaps = free_span * weights / np.sum(weights)
    gaps = min_gap + extra_gaps
    return theta_min + np.concatenate([np.asarray([0.0]), np.cumsum(gaps)])


def pack_params(r_values: np.ndarray, gap_logits: np.ndarray) -> np.ndarray:
    if gap_logits.size:
        return np.concatenate([r_values, gap_logits])
    return r_values.copy()


def unpack_params(params: np.ndarray, section_count: int) -> tuple[np.ndarray, np.ndarray]:
    r_values = params[:section_count]
    gap_logits = params[section_count : 2 * section_count - 1]
    return r_values, gap_logits


def initial_params(section_count: int, digital_w_rad: np.ndarray) -> np.ndarray:
    r_values = np.full(section_count, 0.55, dtype=float)
    gap_logits = np.zeros(max(section_count - 1, 0), dtype=float)
    return pack_params(r_values, gap_logits)


def parameter_bounds(section_count: int, digital_w_rad: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    r_low = np.full(section_count, 0.30, dtype=float)
    r_high = np.full(section_count, 0.98, dtype=float)
    if section_count == 1:
        return r_low, r_high

    gap_low = np.full(section_count - 1, -8.0, dtype=float)
    gap_high = np.full(section_count - 1, 8.0, dtype=float)
    return pack_params(r_low, gap_low), pack_params(r_high, gap_high)


def design_allpass(
    input_data: GroupDelayInput,
    output_dir: Path,
    fs_hz: float,
    section_count: int,
    margin_ns: float | None,
    compensated_ripple_pp_max_ns: float = 0.2,
) -> AllPassDesign:
    if section_count < 1:
        raise ValueError("section_count must be at least 1.")
    if compensated_ripple_pp_max_ns <= 0.0:
        raise ValueError("compensated_ripple_pp_max_ns must be positive.")

    original_delay_ns = input_data.group_delay_ns
    original_ripple_ns = float(np.max(original_delay_ns) - np.min(original_delay_ns))
    original_shape_ns = original_delay_ns - np.mean(original_delay_ns)
    ripple_scale_ns = max(original_ripple_ns, 1.0)
    ripple_weights = 0.25 + 0.75 * (np.abs(original_shape_ns) / max(np.max(np.abs(original_shape_ns)), 1e-9))
    resolved_margin_ns = margin_ns
    if resolved_margin_ns is None:
        resolved_margin_ns = max(0.05, 0.05 * original_ripple_ns)

    digital_w = fs_based_digital_frequency(input_data.freq_hz, fs_hz)
    theta_min, theta_max = theta_limits(digital_w)

    def residual(params: np.ndarray) -> np.ndarray:
        r_values, gap_logits = unpack_params(params, section_count)
        theta_values = ordered_thetas_from_gap_logits(gap_logits, theta_min, theta_max, section_count)
        _, ap_delay_ns = response_phase_and_delay_ns(
            digital_w,
            input_data.omega_rad,
            r_values,
            theta_values,
        )
        ap_shape_ns = ap_delay_ns - np.mean(ap_delay_ns)
        # Drive τ_AP shape toward -τ_pre shape so compensated GD ripple is flattened.
        ripple_cancel_error_ns = ap_shape_ns + original_shape_ns
        return ripple_weights * ripple_cancel_error_ns / ripple_scale_ns

    lower, upper = parameter_bounds(section_count, digital_w)
    x0 = initial_params(section_count, digital_w)
    result = least_squares(
        residual,
        x0,
        bounds=(lower, upper),
        max_nfev=2500,
        ftol=1e-10,
        xtol=1e-10,
        gtol=1e-10,
    )

    r_values, gap_logits = unpack_params(result.x, section_count)
    theta_values = ordered_thetas_from_gap_logits(gap_logits, theta_min, theta_max, section_count)
    order = np.argsort(theta_values)
    r_values = r_values[order]
    theta_values = theta_values[order]

    allpass_phase, allpass_delay_ns = response_phase_and_delay_ns(
        digital_w,
        input_data.omega_rad,
        r_values,
        theta_values,
    )
    compensated_group_delay_ns = input_data.group_delay_ns + allpass_delay_ns
    compensated_phase_rad = input_data.phase_rad + allpass_phase
    center_freq_hz = theta_values * fs_hz / (2.0 * np.pi)

    target_delay_ns = float(np.mean(compensated_group_delay_ns))
    compensated_error = compensated_group_delay_ns - target_delay_ns
    compensated_ripple_pp_ns = float(np.max(compensated_group_delay_ns) - np.min(compensated_group_delay_ns))
    compensated_rms_error_ns = float(np.sqrt(np.mean(compensated_error**2)))
    meets_compensated_ripple_target = compensated_ripple_pp_ns <= compensated_ripple_pp_max_ns

    return AllPassDesign(
        input_data=input_data,
        output_dir=output_dir,
        fs_hz=fs_hz,
        section_count=section_count,
        target_delay_ns=target_delay_ns,
        margin_ns=float(resolved_margin_ns),
        r_values=r_values,
        theta_values_rad=theta_values,
        center_freq_hz=center_freq_hz,
        allpass_phase_rad=allpass_phase,
        allpass_group_delay_ns=allpass_delay_ns,
        compensated_phase_rad=compensated_phase_rad,
        compensated_group_delay_ns=compensated_group_delay_ns,
        compensated_ripple_pp_ns=compensated_ripple_pp_ns,
        compensated_rms_error_ns=compensated_rms_error_ns,
        compensated_ripple_pp_max_ns=float(compensated_ripple_pp_max_ns),
        meets_compensated_ripple_target=meets_compensated_ripple_target,
        optimizer_cost=float(result.cost),
        optimizer_success=bool(result.success),
        optimizer_message=str(result.message),
    )


def save_coefficients_csv(design: AllPassDesign, output_csv: Path) -> None:
    output_csv.parent.mkdir(parents=True, exist_ok=True)
    with output_csv.open("w", newline="", encoding="utf-8") as csv_file:
        writer = csv.writer(csv_file)
        writer.writerow(
            [
                "section",
                "fs_hz",
                "r",
                "theta_rad",
                "center_freq_hz",
                "b0",
                "b1",
                "b2",
                "a0",
                "a1",
                "a2",
            ]
        )
        for idx, (r, theta, center_freq) in enumerate(
            zip(design.r_values, design.theta_values_rad, design.center_freq_hz),
            start=1,
        ):
            c = np.cos(theta)
            b0 = r * r
            b1 = -2.0 * r * c
            b2 = 1.0
            a0 = 1.0
            a1 = -2.0 * r * c
            a2 = r * r
            writer.writerow(
                [
                    idx,
                    f"{design.fs_hz:.6f}",
                    f"{r:.12f}",
                    f"{theta:.12f}",
                    f"{center_freq:.6f}",
                    f"{b0:.12f}",
                    f"{b1:.12f}",
                    f"{b2:.12f}",
                    f"{a0:.12f}",
                    f"{a1:.12f}",
                    f"{a2:.12f}",
                ]
            )


def save_response_csv(design: AllPassDesign, output_csv: Path) -> None:
    output_csv.parent.mkdir(parents=True, exist_ok=True)
    data = design.input_data
    with output_csv.open("w", newline="", encoding="utf-8") as csv_file:
        writer = csv.writer(csv_file)
        writer.writerow(
            [
                "freq_hz",
                "digital_w_rad_per_sample",
                "original_phase_rad",
                "allpass_phase_rad",
                "compensated_phase_rad",
                "original_group_delay_ns",
                "allpass_group_delay_ns",
                "compensated_group_delay_ns",
                "target_delay_ns",
            ]
        )
        for values in zip(
            data.freq_hz,
            fs_based_digital_frequency(data.freq_hz, design.fs_hz),
            data.phase_rad,
            design.allpass_phase_rad,
            design.compensated_phase_rad,
            data.group_delay_ns,
            design.allpass_group_delay_ns,
            design.compensated_group_delay_ns,
        ):
            (
                freq_hz,
                digital_w,
                original_phase,
                allpass_phase,
                compensated_phase,
                original_delay,
                allpass_delay,
                compensated_delay,
            ) = values
            writer.writerow(
                [
                    f"{freq_hz:.6f}",
                    f"{digital_w:.12f}",
                    f"{original_phase:.12f}",
                    f"{allpass_phase:.12f}",
                    f"{compensated_phase:.12f}",
                    f"{original_delay:.9f}",
                    f"{allpass_delay:.9f}",
                    f"{compensated_delay:.9f}",
                    f"{design.target_delay_ns:.9f}",
                ]
            )


def save_metrics_csv(design: AllPassDesign, output_csv: Path) -> None:
    output_csv.parent.mkdir(parents=True, exist_ok=True)
    original_delay = design.input_data.group_delay_ns
    original_mean = float(np.mean(original_delay))
    original_ripple = float(np.max(original_delay) - np.min(original_delay))
    original_rms = float(np.sqrt(np.mean((original_delay - original_mean) ** 2)))

    with output_csv.open("w", newline="", encoding="utf-8") as csv_file:
        writer = csv.writer(csv_file)
        writer.writerow(["metric", "value"])
        writer.writerow(["input_csv", str(design.input_data.input_csv)])
        writer.writerow(["design_model", "fs_based_time_domain_iir"])
        writer.writerow(["optimization_uses_raw_group_delay", True])
        writer.writerow(["optimization_targets_input_ripple_cancellation", True])
        writer.writerow(["fs_hz", f"{design.fs_hz:.6f}"])
        writer.writerow(["section_count", design.section_count])
        writer.writerow(["target_delay_ns", f"{design.target_delay_ns:.9f}"])
        writer.writerow(["target_margin_ns", f"{design.margin_ns:.9f}"])
        writer.writerow(["original_group_delay_ripple_pp_ns", f"{original_ripple:.9f}"])
        writer.writerow(["original_group_delay_rms_around_mean_ns", f"{original_rms:.9f}"])
        writer.writerow(["compensated_group_delay_ripple_pp_ns", f"{design.compensated_ripple_pp_ns:.9f}"])
        writer.writerow(["compensated_group_delay_ripple_pp_max_ns", f"{design.compensated_ripple_pp_max_ns:.9f}"])
        writer.writerow(["meets_compensated_ripple_target", design.meets_compensated_ripple_target])
        writer.writerow(["compensated_group_delay_rms_to_target_ns", f"{design.compensated_rms_error_ns:.9f}"])
        writer.writerow(["optimizer_cost", f"{design.optimizer_cost:.12e}"])
        writer.writerow(["optimizer_success", design.optimizer_success])
        writer.writerow(["optimizer_message", design.optimizer_message])


def plot_group_delay_before_after(design: AllPassDesign, output_path: Path) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    freq = design.input_data.freq_hz
    fig, ax = plt.subplots(figsize=(9, 5))
    ax.plot(freq, design.input_data.group_delay_ns, linewidth=1.3, label="before L1-09")
    ax.plot(freq, design.compensated_group_delay_ns, linewidth=1.3, label="after all-pass")
    ax.axhline(design.target_delay_ns, color="black", linestyle="--", linewidth=1.0, label="target")
    ax.set_title("L1-09 floating all-pass group delay")
    ax.set_xlabel("Frequency (Hz)")
    ax.set_ylabel("Group delay (ns)")
    ax.grid(True, alpha=0.3)
    ax.legend()
    fig.tight_layout()
    fig.savefig(output_path, dpi=160)
    plt.close(fig)


def plot_phase_before_after(design: AllPassDesign, output_path: Path) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    freq = design.input_data.freq_hz
    fig, ax = plt.subplots(figsize=(9, 5))
    ax.plot(freq, design.input_data.phase_rad, linewidth=1.3, label="before L1-09")
    ax.plot(freq, design.compensated_phase_rad, linewidth=1.3, label="after all-pass")
    ax.set_title("L1-09 floating all-pass phase")
    ax.set_xlabel("Frequency (Hz)")
    ax.set_ylabel("Unwrapped phase (rad)")
    ax.grid(True, alpha=0.3)
    ax.legend()
    fig.tight_layout()
    fig.savefig(output_path, dpi=160)
    plt.close(fig)


def parse_args() -> argparse.Namespace:
    default_fs_hz = float(get_common_config_value("fs_hz", 12e9))
    default_sections = int(get_l1_09_config_value("allpass", "sections", 4))
    default_margin_ns = get_l1_09_config_value("allpass", "margin_ns", None)
    default_compensated_ripple_pp_max_ns = float(
        get_l1_09_config_value("allpass", "compensated_ripple_pp_max_ns", 0.2)
    )
    parser = argparse.ArgumentParser(description="Design an fs-based floating multi-section second-order all-pass IIR equalizer.")
    parser.add_argument(
        "--input-csv",
        type=Path,
        default=None,
        help="Input group_delay_analysis.csv. Defaults to latest data/*/l1_09_fix_group_delay/group_delay_analysis.csv.",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=None,
        help="Data output directory. Defaults to data/<run_name>/l1_09_fix_allpass_iir_fs.",
    )
    parser.add_argument(
        "--graph-dir",
        type=Path,
        default=None,
        help="Graph output directory. Defaults to graph/<run_name>/l1_09_fix_allpass_iir_fs.",
    )
    parser.add_argument("--fs-hz", type=float, default=default_fs_hz, help=f"Sampling rate. Default: {default_fs_hz:.6g} Hz.")
    parser.add_argument(
        "--sections",
        type=int,
        default=default_sections,
        help=f"Number of second-order all-pass sections. Default from config_base_plan.json: {default_sections}.",
    )
    parser.add_argument(
        "--margin-ns",
        type=float,
        default=default_margin_ns,
        help="Delay margin above max group delay. Defaults to max(0.05 ns, 5%% of raw ripple).",
    )
    parser.add_argument(
        "--compensated-ripple-pp-max-ns",
        type=float,
        default=default_compensated_ripple_pp_max_ns,
        help=(
            "Pass/fail threshold for raw compensated group-delay ripple peak-to-peak in ns. "
            f"Default from config_base_plan.json: {default_compensated_ripple_pp_max_ns:.6g}."
        ),
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    input_csv = args.input_csv or find_latest_group_delay_csv()
    input_data = load_group_delay_csv(input_csv)
    output_dir = args.output_dir or default_output_dir(input_data)
    graph_dir = args.graph_dir or default_graph_dir(input_data)

    design = design_allpass(
        input_data=input_data,
        output_dir=output_dir,
        fs_hz=args.fs_hz,
        section_count=args.sections,
        margin_ns=args.margin_ns,
        compensated_ripple_pp_max_ns=args.compensated_ripple_pp_max_ns,
    )

    coefficients_csv = output_dir / "allpass_coefficients.csv"
    response_csv = output_dir / "allpass_response.csv"
    metrics_csv = output_dir / "allpass_metrics.csv"
    group_delay_plot = graph_dir / "group_delay_before_after_l1_09.png"
    phase_plot = graph_dir / "phase_before_after_l1_09.png"

    save_coefficients_csv(design, coefficients_csv)
    save_response_csv(design, response_csv)
    save_metrics_csv(design, metrics_csv)
    plot_group_delay_before_after(design, group_delay_plot)
    plot_phase_before_after(design, phase_plot)

    print(f"input_csv: {input_csv}")
    print(f"output_dir: {output_dir}")
    print(f"graph_dir: {graph_dir}")
    print(f"fs_hz: {design.fs_hz:.6f}")
    print(f"section_count: {design.section_count}")
    print(f"target_delay_ns: {design.target_delay_ns:.9f}")
    print(f"compensated_group_delay_ripple_pp_ns: {design.compensated_ripple_pp_ns:.9f}")
    print(f"compensated_group_delay_ripple_pp_max_ns: {design.compensated_ripple_pp_max_ns:.9f}")
    print(f"meets_compensated_ripple_target: {design.meets_compensated_ripple_target}")
    print(f"compensated_group_delay_rms_to_target_ns: {design.compensated_rms_error_ns:.9f}")
    print(f"optimizer_success: {design.optimizer_success}")
    print(f"coefficients_csv: {coefficients_csv}")
    print(f"response_csv: {response_csv}")
    print(f"metrics_csv: {metrics_csv}")
    print(f"group_delay_plot: {group_delay_plot}")
    print(f"phase_plot: {phase_plot}")


if __name__ == "__main__":
    main()
