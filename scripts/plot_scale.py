#!/usr/bin/env python3
"""
Plot rdma_scal scalability curves from results/scale.csv.

Figures:
  A   - Out-WRITE / In-WRITE / Out-SEND-UD
  B   - Out-WRITE vs Out-READ
  C   - Out-WRITE inline vs DMA
  all - plotted curves on one canvas (In-SEND omitted)

Usage:
  python3 scripts/plot_scale.py
  python3 scripts/plot_scale.py --csv results/scale.csv --out-dir results --x n
  python3 scripts/plot_scale.py --fig A B all --x q
"""

from __future__ import annotations

import argparse
import csv
from collections import defaultdict
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

STYLE = {
    "font.size": 12,
    "axes.labelsize": 13,
    "axes.titlesize": 14,
    "legend.fontsize": 10,
    "xtick.labelsize": 11,
    "ytick.labelsize": 11,
    "axes.grid": True,
    "grid.alpha": 0.35,
    "grid.linestyle": "--",
    "figure.dpi": 140,
    "savefig.dpi": 220,
    "savefig.bbox": "tight",
}

# Display order + style for known curves
CURVE_STYLE = {
    "Out-WRITE-UC-inl": {"color": "#d62728", "marker": "o", "ls": "-"},
    "In-WRITE-UC-inl": {"color": "#1f77b4", "marker": "s", "ls": "-"},
    "Out-SEND-UD-inl": {"color": "#2ca02c", "marker": "^", "ls": "-"},
    "Out-READ-RC-dma": {"color": "#9467bd", "marker": "D", "ls": "--"},
    "Out-WRITE-UC-dma": {"color": "#ff7f0e", "marker": "v", "ls": "--"},
    # "In-SEND-UD-inl": {"color": "#17becf", "marker": "P", "ls": "-."},
}

# Commented out of default figures; uncomment style above + entries below to restore.
SKIP_CURVES = {
    "In-SEND-UD-inl",
    "In-SEND-UD-dma",
}

FIG_CURVES = {
    "A": [
        "Out-WRITE-UC-inl",
        "In-WRITE-UC-inl",
        "Out-SEND-UD-inl",
    ],
    "B": [
        "Out-WRITE-UC-inl",
        "Out-READ-RC-dma",
    ],
    "C": [
        "Out-WRITE-UC-inl",
        "Out-WRITE-UC-dma",
        # "In-SEND-UD-inl",
    ],
    "all": None,  # filled at runtime from CSV
}

TITLES = {
    "A": "Fig.A - WRITE and SEND-UD scalability",
    "B": "Fig.B - Outbound WRITE vs READ",
    # "C": "Fig.C - Out-WRITE inline vs DMA (+ In-SEND-UD)",
    "C": "Fig.C - Out-WRITE inline vs DMA",
    "all": "All scalability curves",
}


def load_csv(path: Path) -> dict[str, list[tuple[int, int, float]]]:
    """curve -> list of (n, active_q_or_dest, mops), sorted by n."""
    data: dict[str, list[tuple[int, int, float]]] = defaultdict(list)
    with path.open(newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            if not row.get("curve"):
                continue
            try:
                n = int(row["n"])
                q = int(float(row["active_q_or_dest"]))
                mops = float(row["mops"])
            except (KeyError, ValueError):
                continue
            data[row["curve"]].append((n, q, mops))
    for c in data:
        data[c].sort(key=lambda t: t[0])
    return data


def x_of(row: tuple[int, int, float], which: str) -> int:
    n, q, _ = row
    return n if which == "n" else q


def xlabel_for(which: str) -> str:
    if which == "n":
        return "N (#procs per side)"
    return "Active QPs or destinations (Q)"


def _plot_one(
    data: dict[str, list[tuple[int, int, float]]],
    curves: list[str],
    out_path: Path,
    title: str,
    x_which: str,
    figsize: tuple[float, float],
    legend_outside: bool = False,
) -> None:
    plt.rcParams.update(STYLE)
    fig, ax = plt.subplots(figsize=figsize)

    plotted = 0
    for name in curves:
        series = data.get(name)
        if not series:
            print(f"  warn: missing curve {name}")
            continue
        xs = [x_of(r, x_which) for r in series]
        ys = [r[2] for r in series]
        st = CURVE_STYLE.get(
            name, {"color": None, "marker": "o", "ls": "-"}
        )
        ax.plot(
            xs,
            ys,
            label=name,
            color=st["color"],
            marker=st["marker"],
            linestyle=st["ls"],
            linewidth=2.0,
            markersize=7,
        )
        plotted += 1

    if plotted == 0:
        plt.close(fig)
        print(f"  skip {out_path.name}: no data")
        return

    ax.set_xlabel(xlabel_for(x_which))
    ax.set_ylabel("Throughput (Mops)")
    ax.set_title(title)
    ax.set_ylim(bottom=0)

    # X ticks: for N-axis use 4,8,12,16,... (keep curve points at 1,2 if present)
    if plotted and x_which == "n":
        all_xs: list[int] = []
        for name in curves:
            series = data.get(name)
            if series:
                all_xs.extend(x_of(r, x_which) for r in series)
        if all_xs:
            xmax = max(all_xs)
            ticks = list(range(4, xmax + 1, 4))
            if ticks:
                ax.set_xticks(ticks)
                ax.set_xlim(left=0, right=max(xmax, ticks[-1]) * 1.02)

    if legend_outside:
        ax.legend(
            loc="upper left",
            bbox_to_anchor=(1.02, 1.0),
            borderaxespad=0.0,
            frameon=True,
        )
        fig.tight_layout(rect=(0, 0, 0.78, 1))
    else:
        ax.legend(loc="best", frameon=True)
        fig.tight_layout()

    out_path.parent.mkdir(parents=True, exist_ok=True)
    for ext in ("pdf", "png"):
        p = out_path.with_suffix("." + ext)
        fig.savefig(p)
        print(f"  wrote {p}")
    plt.close(fig)


def main() -> None:
    ap = argparse.ArgumentParser(description="Plot rdma_scal scale.csv")
    ap.add_argument(
        "--csv",
        type=Path,
        default=None,
        help="path to scale.csv (default: <repo>/results/scale.csv)",
    )
    ap.add_argument(
        "--out-dir",
        type=Path,
        default=None,
        help="output directory (default: same as CSV parent)",
    )
    ap.add_argument(
        "--fig",
        nargs="+",
        default=["A", "B", "C", "all"],
        choices=["A", "B", "C", "all"],
        help="which figures to emit",
    )
    ap.add_argument(
        "--x",
        choices=["n", "q"],
        default="n",
        help="x-axis: paper N, or active_q_or_dest",
    )
    ap.add_argument(
        "--suffix",
        default="",
        help="output name suffix, e.g. _server03 for scale_fig_A_server03.pdf "
        "(auto from CSV stem scale_<tag>.csv if omitted)",
    )
    args = ap.parse_args()

    root = Path(__file__).resolve().parents[1]
    csv_path = args.csv or (root / "results" / "scale.csv")
    out_dir = args.out_dir or csv_path.parent

    if not csv_path.is_file():
        raise SystemExit(f"CSV not found: {csv_path}")

    suffix = args.suffix
    if not suffix:
        stem0 = csv_path.stem  # scale_server03 / scale / scale_both
        if stem0.startswith("scale_") and stem0 != "scale_":
            suffix = stem0[len("scale") :]  # _server03
        elif stem0 == "scale":
            suffix = ""

    data = load_csv(csv_path)
    print(f"loaded {csv_path}: {len(data)} curves, x={args.x}, suffix={suffix!r}")

    # Prefer known style order for "all", then any extras from CSV (skip In-SEND)
    all_curves = [c for c in CURVE_STYLE if c in data and c not in SKIP_CURVES]
    for c in sorted(data):
        if c not in all_curves and c not in SKIP_CURVES:
            all_curves.append(c)
    FIG_CURVES["all"] = all_curves

    tag = suffix.lstrip("_") if suffix else ""
    for fig_id in args.fig:
        curves = FIG_CURVES[fig_id]
        assert curves is not None
        if fig_id == "all":
            figsize = (16.0, 9.0)
            legend_outside = True
            stem = f"scale_fig_all{suffix}"
        elif fig_id == "A":
            figsize = (8.0, 5.5)
            legend_outside = False
            stem = f"scale_fig_A{suffix}"
        else:
            figsize = (8.0, 5.5)
            legend_outside = False
            stem = f"scale_fig_{fig_id}{suffix}"

        title = TITLES[fig_id]
        if tag:
            title = f"{title} [{tag}]"

        _plot_one(
            data,
            curves,
            out_dir / stem,
            title,
            args.x,
            figsize,
            legend_outside=legend_outside,
        )


if __name__ == "__main__":
    main()
