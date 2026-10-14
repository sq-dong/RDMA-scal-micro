#!/usr/bin/env python3
"""
Plot rdma_scal CSV into three figure sets:
  all      - every curve in the CSV
  starred  - focused verb subset
  A        - Out-WRITE-UC-inl, In-WRITE-UC-inl, Out-SEND-UD-inl

Line color / marker / linestyle follow the historical scale_fig_all_both.pdf
style for overlapping verbs, extended consistently to the full matrix.
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
    "legend.fontsize": 9,
    "xtick.labelsize": 11,
    "ytick.labelsize": 11,
    "axes.grid": True,
    "grid.alpha": 0.35,
    "grid.linestyle": "--",
    "figure.dpi": 140,
    "savefig.dpi": 220,
    "savefig.bbox": "tight",
}

# Starred verbs from the experiment plan.
STARRED = [
    "In-READ-RC-dma",
    "Out-READ-RC-dma",
    "In-WRITE-RC-inl",
    "Out-WRITE-RC-inl",
    "In-WRITE-UC-inl",
    "Out-WRITE-UC-inl",
    "In-SEND-UD-dma",
    "Out-SEND-UD-inl",
]

FIG_A = [
    "Out-WRITE-UC-inl",
    "In-WRITE-UC-inl",
    "Out-SEND-UD-inl",
]

# Color / marker / linestyle aligned with results/scale_fig_all_both.pdf
# (git HEAD). First five entries match that figure exactly.
# Convention for extensions: inl=solid, dma=dashed; In uses square/diamond,
# Out uses circle/triangle; same verb family shares a hue.
CURVE_STYLE: dict[str, dict[str, str]] = {
    # --- exact match to scale_fig_all_both.pdf ---
    "Out-WRITE-UC-inl": {"color": "#d62728", "marker": "o", "ls": "-"},
    "In-WRITE-UC-inl": {"color": "#1f77b4", "marker": "s", "ls": "-"},
    "Out-SEND-UD-inl": {"color": "#2ca02c", "marker": "^", "ls": "-"},
    "Out-READ-RC-dma": {"color": "#9467bd", "marker": "D", "ls": "--"},
    "Out-WRITE-UC-dma": {"color": "#ff7f0e", "marker": "v", "ls": "--"},
    # --- READ ---
    "In-READ-RC-dma": {"color": "#c5b0d5", "marker": "s", "ls": "--"},
    # --- WRITE-UC ---
    "In-WRITE-UC-dma": {"color": "#aec7e8", "marker": "D", "ls": "--"},
    # --- WRITE-RC ---
    "Out-WRITE-RC-inl": {"color": "#8c564b", "marker": "o", "ls": "-"},
    "In-WRITE-RC-inl": {"color": "#c49c94", "marker": "s", "ls": "-"},
    "Out-WRITE-RC-dma": {"color": "#8c564b", "marker": "v", "ls": "--"},
    "In-WRITE-RC-dma": {"color": "#c49c94", "marker": "D", "ls": "--"},
    # --- SEND-UD ---
    "Out-SEND-UD-dma": {"color": "#98df8a", "marker": "v", "ls": "--"},
    "In-SEND-UD-inl": {"color": "#17becf", "marker": "s", "ls": "-"},
    "In-SEND-UD-dma": {"color": "#9edae5", "marker": "D", "ls": "--"},
    # --- SEND-UC ---
    "Out-SEND-UC-inl": {"color": "#e377c2", "marker": "^", "ls": "-"},
    "Out-SEND-UC-dma": {"color": "#f7b6d2", "marker": "v", "ls": "--"},
    "In-SEND-UC-inl": {"color": "#bcbd22", "marker": "s", "ls": "-"},
    "In-SEND-UC-dma": {"color": "#dbdb8d", "marker": "D", "ls": "--"},
    # --- SEND-RC ---
    "Out-SEND-RC-inl": {"color": "#7f7f7f", "marker": "^", "ls": "-"},
    "Out-SEND-RC-dma": {"color": "#c7c7c7", "marker": "v", "ls": "--"},
    "In-SEND-RC-inl": {"color": "#393b79", "marker": "s", "ls": "-"},
    "In-SEND-RC-dma": {"color": "#9c9ede", "marker": "D", "ls": "--"},
}

_FALLBACK_MARKERS = ["o", "s", "^", "v", "D", "P", "X", "*"]
_FALLBACK_COLORS = [
    "#d62728",
    "#1f77b4",
    "#2ca02c",
    "#9467bd",
    "#ff7f0e",
    "#17becf",
    "#8c564b",
    "#e377c2",
    "#7f7f7f",
    "#bcbd22",
]


def style_for(curve: str) -> dict[str, str]:
    if curve in CURVE_STYLE:
        return CURVE_STYLE[curve]
    # Stable fallback for any unexpected name.
    h = 0
    for ch in curve:
        h = (h * 131 + ord(ch)) & 0xFFFFFFFF
    ls = "--" if curve.endswith("-dma") else "-"
    return {
        "color": _FALLBACK_COLORS[h % len(_FALLBACK_COLORS)],
        "marker": _FALLBACK_MARKERS[h % len(_FALLBACK_MARKERS)],
        "ls": ls,
    }


def load_csv(path: Path) -> dict[str, list[tuple[int, int, float]]]:
    """curve -> list of (n_srv, active_q, mops), sorted by n_srv."""
    data: dict[str, list[tuple[int, int, float]]] = defaultdict(list)
    with path.open(newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            if not row.get("curve"):
                continue
            try:
                # New schema: n_srv; legacy: n
                n = int(row["n_srv"] if "n_srv" in row and row["n_srv"] else row["n"])
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
        return "N (server processes per side)"
    return "Number of active QPs (Q)"


def fig_stem(base: str, x_which: str) -> str:
    """Keep legacy names for --x n; QP-axis figures get a _Q suffix."""
    if x_which == "n":
        return base
    return f"{base}_Q"


def ordered_curves(data: dict[str, list[tuple[int, int, float]]]) -> list[str]:
    """Prefer CURVE_STYLE order (same as historical both figure), then extras."""
    ordered = [c for c in CURVE_STYLE if c in data]
    for c in sorted(data):
        if c not in ordered:
            ordered.append(c)
    return ordered


def plot_one(
    data: dict[str, list[tuple[int, int, float]]],
    curves: list[str],
    out_path: Path,
    title: str,
    x_which: str,
    figsize: tuple[float, float] = (10.0, 6.5),
    legend_outside: bool = True,
) -> None:
    plt.rcParams.update(STYLE)
    fig, ax = plt.subplots(figsize=figsize)

    # For --x q: place points on an even categorical axis (index), label ticks
    # with the real QP counts so large Q values don't crush small ones.
    q_even = x_which == "q"
    q_levels: list[int] = []
    if q_even:
        q_set: set[int] = set()
        for curve in curves:
            for r in data.get(curve, []):
                q_set.add(x_of(r, "q"))
        q_levels = sorted(q_set)
        q_to_pos = {q: i for i, q in enumerate(q_levels)}

    drawn = 0
    all_xs: list[int] = []
    for curve in curves:
        rows = data.get(curve)
        if not rows:
            continue
        # Sort by the chosen x so curves are monotonic on that axis.
        keyed = sorted(((x_of(r, x_which), r[2]) for r in rows), key=lambda t: t[0])
        raw_xs = [t[0] for t in keyed]
        ys = [t[1] for t in keyed]
        if q_even:
            xs = [q_to_pos[q] for q in raw_xs]
        else:
            xs = raw_xs
        all_xs.extend(raw_xs if not q_even else xs)
        st = style_for(curve)
        ax.plot(
            xs,
            ys,
            label=curve,
            color=st["color"],
            marker=st["marker"],
            linestyle=st["ls"],
            linewidth=2.0,
            markersize=7,
        )
        drawn += 1
    if drawn == 0:
        plt.close(fig)
        print(f"  skip {out_path.name}: no matching curves")
        return

    ax.set_xlabel(xlabel_for(x_which))
    ax.set_ylabel("Throughput (Mops)")
    ax.set_title(title)
    ax.set_ylim(bottom=0)
    if x_which == "n":
        xmax = max(all_xs) if all_xs else 32
        ticks = list(range(4, max(xmax, 32) + 1, 4))
        ax.set_xticks(ticks)
    else:
        # Even spacing: tick at each category index, label = QP count.
        ax.set_xticks(list(range(len(q_levels))))
        ax.set_xticklabels([str(q) for q in q_levels])
        if q_levels:
            ax.set_xlim(-0.3, len(q_levels) - 0.7)
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
    fig.savefig(out_path.with_suffix(".pdf"))
    fig.savefig(out_path.with_suffix(".png"))
    plt.close(fig)
    print(f"  wrote {out_path.with_suffix('.pdf')}")
    print(f"  wrote {out_path.with_suffix('.png')}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--csv", type=Path, default=None)
    ap.add_argument("--out-dir", type=Path, default=None)
    ap.add_argument(
        "--x",
        choices=["n", "q"],
        default="n",
        help="x-axis: n (server procs, default) or q (active QPs)",
    )
    ap.add_argument(
        "--fig",
        nargs="+",
        default=["all", "starred", "A"],
        choices=["all", "starred", "A"],
    )
    args = ap.parse_args()

    root = Path(__file__).resolve().parents[1]
    csv_path = args.csv or (root / "results" / "scale.csv")
    out_dir = args.out_dir or csv_path.parent
    out_dir.mkdir(parents=True, exist_ok=True)

    if not csv_path.is_file():
        raise SystemExit(f"CSV not found: {csv_path}")

    data = load_csv(csv_path)
    print(f"loaded {csv_path}: {len(data)} curves, x={args.x}")

    # Larger canvases for dense multi-curve plots.
    fig_all = (20.0, 11.0)
    fig_starred = (18.0, 10.0)
    fig_a = (9.0, 6.0)

    all_curves = ordered_curves(data)
    for fig_id in args.fig:
        if fig_id == "all":
            plot_one(
                data,
                all_curves,
                out_dir / fig_stem("scale_fig_all", args.x),
                "All measured curves",
                args.x,
                figsize=fig_all,
                legend_outside=True,
            )
        elif fig_id == "starred":
            plot_one(
                data,
                STARRED,
                out_dir / fig_stem("scale_fig_starred", args.x),
                "Starred verb subset",
                args.x,
                figsize=fig_starred,
                legend_outside=True,
            )
        else:
            plot_one(
                data,
                FIG_A,
                out_dir / fig_stem("scale_fig_A", args.x),
                "Fig.A - WRITE-UC-inl and SEND-UD-inl",
                args.x,
                figsize=fig_a,
                legend_outside=False,
            )


if __name__ == "__main__":
    main()
