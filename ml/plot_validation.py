"""Chart: MODIS-VIIRS agreement before vs after harmonization (from validate.py's results.json).

Run:  uv run --project ml python ml/plot_validation.py
Writes ml/outputs/harmonized/agreement.png
"""

from __future__ import annotations

import json

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

from harmonize import HARM_OUT

SURFACE, INK, INK2, INK3, RULE = "#101217", "#f1ede6", "#b4afa6", "#7e7a73", "#23262c"
BEFORE, AFTER = "#199e70", "#9085e9"   # validated pair (dark surface): aqua, violet


def main() -> None:
    res = json.loads((HARM_OUT / "results.json").read_text())["years"]
    years = sorted(res)
    panels = [
        ("Match rate", "Share of detections the other sensor also saw",
         lambda r: r["match_rate"]["before_raw_overlay"]["all"], lambda r: r["match_rate"]["after_harmonized"]["all"]),
        ("Fire-map overlap", "Share of ~1 km fire cell-days both sensors report",
         lambda r: r["cell_day_overlap"]["before_raw"]["jaccard"], lambda r: r["cell_day_overlap"]["after_harmonized"]["jaccard"]),
    ]
    plt.rcParams.update({"font.family": "DejaVu Sans", "text.color": INK, "axes.labelcolor": INK2})
    fig, axes = plt.subplots(1, 2, figsize=(10, 4.6), dpi=200, facecolor=SURFACE)
    w, gap = 0.34, 0.03
    for ax, (title, sub, fb, fa) in zip(axes, panels):
        ax.set_facecolor(SURFACE)
        for i, y in enumerate(years):
            for off, f, col in ((-(w + gap) / 2, fb, BEFORE), ((w + gap) / 2, fa, AFTER)):
                v = f(res[y])
                ax.bar(i + off, v, w, color=col, linewidth=0)
                ax.text(i + off, v + 0.015, f"{v:.0%}", ha="center", va="bottom", color=INK, fontsize=11,
                        fontweight="bold")
        ax.set_xlim(-0.6, len(years) - 0.4)
        ax.set_ylim(0, 1)
        ax.set_xticks(range(len(years)), [f"California {y}" for y in years], color=INK2, fontsize=10)
        ax.set_yticks([0, .25, .5, .75, 1], ["0%", "25%", "50%", "75%", "100%"], color=INK3, fontsize=9)
        ax.tick_params(length=0)
        ax.grid(axis="y", color=RULE, linewidth=0.8)
        ax.set_axisbelow(True)
        for s in ax.spines.values():
            s.set_visible(False)
        ax.axhline(0, color=INK3, linewidth=0.8)
        ax.set_title(f"{title}\n", loc="left", fontsize=13, fontweight="bold", color=INK, pad=4)
        ax.text(0, 1.035, sub, transform=ax.transAxes, fontsize=9.5, color=INK2)
    handles = [plt.Rectangle((0, 0), 1, 1, color=BEFORE), plt.Rectangle((0, 0), 1, 1, color=AFTER)]
    fig.legend(handles, ["Before: raw MODIS and VIIRS overlaid", "After: harmonized (false alarms dropped, matched)"],
               loc="lower center", ncol=2, frameon=False, fontsize=10, labelcolor=INK2, bbox_to_anchor=(0.5, 0.0))
    fig.suptitle("MODIS and VIIRS agree about twice as often after harmonization", x=0.01, ha="left",
                 fontsize=15, fontweight="bold", color=INK, y=0.99)
    fig.tight_layout(rect=(0, 0.07, 1, 0.95), w_pad=3)
    out = HARM_OUT / "agreement.png"
    fig.savefig(out, facecolor=SURFACE)
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
