"""The expert-skipping figure for social posts: iPhone 18 Pro decode speed at
24 and 32 slots with skipping off / 0.08 / 0.10, beside the graded accuracy of
the same three settings.

Usage: make_figure.py <out dir> [--light] [--portrait]

Speed: results/benchmark-results-2026-11-10-ios-settings-sweep/ (summary-output.txt).
Accuracy: results/validation-results-2026-11-11-skip-accuracy/ (score-output.txt).
"""
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import PathPatch
from matplotlib.path import Path

out_dir = sys.argv[1]
LIGHT = "--light" in sys.argv
PORTRAIT = "--portrait" in sys.argv

# ---- data -------------------------------------------------------------------
# tok/s, short / medium / long; 24 / 0.08 is the mean of runs 1 and 7.
SPEED = {
    (24, "off"): [13.812, 11.551, 10.698],
    (24, "0.08"): [(16.148 + 17.186) / 2, (15.523 + 15.542) / 2, (14.004 + 12.610) / 2],
    (24, "0.10"): [17.146, 18.398, 16.676],
    (32, "off"): [16.887, 15.441, 13.820],
    (32, "0.08"): [19.594, 17.880, 15.435],
    (32, "0.10"): [21.302, 20.051, 18.650],
}
MEMORY = {24: "3.2 GB", 32: "4.0 GB"}  # app footprint while decoding (runs 1 and 2)
ACC = {  # accuracy % from correct counts, and the paired change against off in points
    "MMLU-Pro": {"off": (100 * 1551 / 2002, None), "0.08": (100 * 1540 / 2002, "−0.55"),
                 "0.10": (100 * 1546 / 2002, "−0.25")},
    "GSM8K": {"off": (100 * 1244 / 1319, None), "0.08": (100 * 1230 / 1319, "−1.06*"),
              "0.10": (100 * 1238 / 1319, "−0.45")},
}
ARMS = ["off", "0.08", "0.10"]
ARM_LABEL = {"off": "Skipping off", "0.08": "Skip threshold 0.08 (default)",
             "0.10": "Skip threshold 0.10"}

# ---- theme ------------------------------------------------------------------
if LIGHT:
    T = dict(page="#f9f9f7", surface="#fcfcfb", ink="#0b0b0b", ink2="#52514e",
             muted="#898781", grid="#e1e0d9", base="#c3c2b7",
             series={"off": "#a3a29c", "0.08": "#2a78d6", "0.10": "#eb6834"})
else:
    T = dict(page="#0d0d0d", surface="#1a1a19", ink="#f0efec", ink2="#c3c2b7",
             muted="#898781", grid="#2c2c2a", base="#383835",
             series={"off": "#8f8e88", "0.08": "#3987e5", "0.10": "#d95926"})
plt.rcParams.update({
    "font.family": ["Helvetica Neue", "Helvetica", "Arial", "DejaVu Sans"],
    "font.size": 15, "text.color": T["ink"], "axes.edgecolor": T["base"],
    "xtick.color": T["muted"], "ytick.color": T["muted"],
})


def mean(v):
    return sum(v) / len(v)


def bar(ax, x, h, w, color, radius_px=14):
    """A column with a rounded data end, square at the baseline."""
    # The radius in data units, separately for x and y.
    fig = ax.figure
    fig.canvas.draw()
    (x0, y0), (x1, y1) = ax.transData.transform([(0, 0), (1, 1)])
    rx, ry = radius_px / (x1 - x0), radius_px / (y1 - y0)
    rx, ry = min(rx, w / 2), min(ry, h)
    l, r = x - w / 2, x + w / 2
    k = 0.5523  # cubic approximation of a quarter circle
    verts = [(l, 0), (l, h - ry), (l, h - ry + k * ry), (l + rx - k * rx, h), (l + rx, h),
             (r - rx, h), (r - rx + k * rx, h), (r, h - ry + k * ry), (r, h - ry),
             (r, 0), (l, 0)]
    codes = [Path.MOVETO, Path.LINETO, Path.CURVE4, Path.CURVE4, Path.CURVE4,
             Path.LINETO, Path.CURVE4, Path.CURVE4, Path.CURVE4, Path.LINETO,
             Path.CLOSEPOLY]
    ax.add_patch(PathPatch(Path(verts, codes), facecolor=color, edgecolor="none", zorder=3))


def style(ax, ymax, step):
    ax.set_facecolor(T["surface"])
    ax.set_ylim(0, ymax)
    ax.set_yticks(range(0, ymax + 1, step))
    ax.grid(axis="y", color=T["grid"], linewidth=1, zorder=0)
    for side in ("top", "right", "left"):
        ax.spines[side].set_visible(False)
    ax.spines["bottom"].set_color(T["base"])
    ax.tick_params(axis="y", length=0, labelsize=13, pad=8)
    ax.tick_params(axis="x", length=0)


# ---- layout -----------------------------------------------------------------
TITLE = "Gemma 4 26B on an iPhone 18 Pro: skipping experts"
SUB = ("Skipping low-weight experts that would need a storage read: 15–45% faster "
       "decoding, while accuracy moves by about a point or less")
NOTES = [
    "Speed: iPhone 18 Pro (12 GB), Gemma 4 26B-A4B in 4 bits; mean of three prompts (61, 430 and "
    "3,015 tokens); one run per setting, two for 24 / 0.08; percentages against 24 slots, off.",
    "Accuracy: greedy, in a GPU simulation of the app at 24 slots. Replaying the phone's own replies, "
    "it found the same experts in memory as the phone (cache hit rate within 0.13 percentage points).",
    "Changes are in percentage points; 95% range ±1.1 (MMLU-Pro), ±0.7 (GSM8K).  * Larger than chance "
    "explains; about half of it is right answers marked wrong for their format (\"16.00\" for \"16\").",
]
if PORTRAIT:
    fig = plt.figure(figsize=(10.8, 13.5), dpi=200)  # 2160 × 2700, 4:5
    X0, X1 = 0.09, 0.95
    left = fig.add_axes([X0, 0.52, X1 - X0, 0.22])
    right = fig.add_axes([X0, 0.24, X1 - X0, 0.175])
    title_y, sub_y, legend_y, notes_y = 0.965, 0.878, 0.80, 0.168
    TITLE = TITLE.replace(": ", ":\n")
    SUB = SUB.replace("read: ", "read:\n")
    NOTES = [
        "Speed: iPhone 18 Pro (12 GB), Gemma 4 26B-A4B in 4 bits; mean of three prompts (61, 430",
        "and 3,015 tokens); one run per setting, two for 24 / 0.08; % against 24 slots, off.",
        "Accuracy: greedy, in a GPU simulation of the app at 24 slots. Replaying the phone's replies,",
        "it found the same experts in memory as the phone (hit rate within 0.13 percentage points).",
        "Changes in percentage points; 95% range ±1.1 (MMLU-Pro), ±0.7 (GSM8K). * Larger than",
        "chance explains; about half is right answers marked wrong for format (\"16.00\" for \"16\").",
    ]
else:
    fig = plt.figure(figsize=(16, 9), dpi=200)  # 3200 × 1800, 16:9
    X0, X1 = 0.055, 0.975
    left = fig.add_axes([X0, 0.235, 0.53, 0.46])
    right = fig.add_axes([0.665, 0.235, X1 - 0.665, 0.46])
    title_y, sub_y, legend_y, notes_y = 0.94, 0.875, 0.80, 0.125
fig.patch.set_facecolor(T["page"])

fig.text(X0, title_y, TITLE, fontsize=31 if PORTRAIT else 30, fontweight="bold",
         color=T["ink"], va="top", linespacing=1.15)
fig.text(X0, sub_y, SUB, fontsize=17, color=T["ink2"], va="top", linespacing=1.4)

from matplotlib.patches import Patch
fig.legend(handles=[Patch(facecolor=T["series"][a], edgecolor="none", label=ARM_LABEL[a])
                    for a in ARMS],
           loc="center left", bbox_to_anchor=(X0 - 0.006, legend_y), ncol=3, frameon=False,
           fontsize=15, labelcolor=T["ink2"], handlelength=1.1, handleheight=1.1,
           handletextpad=0.6, columnspacing=2.0 if PORTRAIT else 2.4)


def label(ax, x, v, text, rise, **kw):
    """Text above a bar, offset in points so it holds at any axes height."""
    ax.annotate(text, (x, v), xytext=(0, rise), textcoords="offset points", ha="center",
                va="bottom", zorder=4, **kw)


# ---- speed ------------------------------------------------------------------
style(left, 25, 5)
left.set_xlim(-0.75, 6.75)
W = 0.62
base = mean(SPEED[(24, "off")])
for g, slots in enumerate((24, 32)):
    for i, arm in enumerate(ARMS):
        x = g * 4 + i
        v = mean(SPEED[(slots, arm)])
        bar(left, x, v, W, T["series"][arm])
        label(left, x, v, f"{v:.1f}", 5, fontsize=17, fontweight="bold", color=T["ink"])
        if (slots, arm) != (24, "off"):
            label(left, x, v, f"+{100 * (v / base - 1):.0f}%", 25, fontsize=13,
                  color=T["muted"])
left.set_xticks([1, 5])
left.set_xticklabels([f"24 expert slots  ·  {MEMORY[24]} of memory",
                      f"32 expert slots  ·  {MEMORY[32]} of memory"],
                     fontsize=15, color=T["ink2"])
left.tick_params(axis="x", pad=12)
left.set_title("Decode speed on the phone, tokens per second", loc="left", fontsize=17,
               fontweight="bold", color=T["ink"], pad=18)

# ---- accuracy ---------------------------------------------------------------
style(right, 100, 20)
right.set_ylim(0, 115)
right.set_xlim(-0.75, 6.75)
for g, task in enumerate(ACC):
    for i, arm in enumerate(ARMS):
        x = g * 4 + i
        v, d = ACC[task][arm]
        bar(right, x, v, W, T["series"][arm])
        label(right, x, v, f"{v:.1f}", 5, fontsize=16, fontweight="bold", color=T["ink"])
        if d:
            label(right, x, v, d, 25, fontsize=13, color=T["muted"])
right.set_xticks([1, 5])
right.set_xticklabels(["MMLU-Pro\n2,002 questions", "GSM8K\n1,319 questions"],
                      fontsize=15, color=T["ink2"], linespacing=1.3)
right.tick_params(axis="x", pad=10)
right.set_title("Accuracy, %, and the change against off", loc="left", fontsize=17,
                fontweight="bold", color=T["ink"], pad=18)

# ---- footnote ---------------------------------------------------------------
fig.text(X0, notes_y, "\n".join(NOTES), fontsize=11.5, color=T["muted"], va="top",
         linespacing=1.6)
if PORTRAIT:  # the credit: bottom right in portrait, beside the title in landscape
    fig.text(X1, 0.018, "Localita  ·  github.com/maxslamdunk/localita", fontsize=13,
             color=T["ink2"], ha="right", va="bottom")
else:
    fig.text(X1, title_y - 0.012, "Localita  ·  github.com/maxslamdunk/localita", fontsize=13,
             color=T["ink2"], ha="right", va="top")

name = "skip-speed-accuracy" + ("-portrait" if PORTRAIT else "") + ("-light" if LIGHT else "")
fig.savefig(f"{out_dir}/{name}.png", facecolor=T["page"])
print(f"{out_dir}/{name}.png")
