"""Case study: the 2024 Park Fire (Butte and Tehama counties, 429,603 acres, California's 4th largest).

What the harmonized record shows that raw MODIS or raw VIIRS alone misses:
  - Suomi NPP VIIRS has no California data on 24-28 July 2024, the Park Fire's first five days and
    its fastest growth. VIIRS alone first sees the fire on 29 July. MODIS (Aqua) saw it at 15:33 PDT
    on 24 July, so the harmonized record starts on day one.
  - VIIRS's 375 m pixels keep finding the smouldering edges after MODIS stops seeing anything
    (from 10 August), so the harmonized record also covers the tail of the fire.

Run:  uv run --project ml python ml/case_study.py      (after harmonize.py 2024)
Writes ml/outputs/harmonized/park_fire.png, park_fire.json and park_fire_cells.geojson
"""

from __future__ import annotations

import json

import geopandas as gpd
import matplotlib
matplotlib.use("Agg")
import matplotlib.dates as mdates
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from matplotlib.patches import Patch
from shapely.geometry import box

from harmonize import CELL, DET_OUT, HARM_OUT, TZ, cell_of
from validate import perimeters

YEAR, FIRE = 2024, "Park"
START, END = "2024-07-24", "2024-08-20"
SURFACE, INK, INK2, INK3, RULE = "#101217", "#f1ede6", "#b4afa6", "#7e7a73", "#23262c"
# Validated all-pairs on the dark surface: orange = MODIS, blue = VIIRS (as on the site), aqua = both
COLORS = {"MODIS": "#d95926", "VIIRS": "#3987e5", "MODIS+VIIRS": "#199e70"}
LABELS = {"MODIS": "MODIS only", "VIIRS": "VIIRS only", "MODIS+VIIRS": "Both sensors"}


def local_date(t: pd.Series) -> pd.Series:
    return t.dt.tz_localize("UTC").dt.tz_convert(TZ).dt.strftime("%Y-%m-%d")


def main() -> None:
    per = perimeters(YEAR)
    fire = per[per.name == FIRE].sort_values("acres").iloc[[-1]]
    area = fire.to_crs(3310).buffer(1000).to_crs(4326).iloc[0]          # one MODIS pixel of tolerance

    det = pd.read_parquet(DET_OUT / f"detections_{YEAR}.parquet")
    det["date"] = local_date(det.time)
    det = det[(det.date >= START) & (det.date <= END)]
    det = det[gpd.GeoSeries(gpd.points_from_xy(det.lon, det.lat), crs=4326).within(area).values]
    rec = pd.read_csv(HARM_OUT / f"harmonized_fires_{YEAR}.csv")
    rec = rec[(rec.date >= START) & (rec.date <= END)]
    rec = rec[gpd.GeoSeries(gpd.points_from_xy(rec.lon, rec.lat), crs=4326).within(area).values]

    # Raw single-sensor views (no classifier), on the same ~1 km cells
    det["ci"], det["cj"] = cell_of(det.lat, det.lon)
    det["cell_id"] = det.ci.astype(str) + "_" + det.cj.astype(str)
    raw_cells = {s: set(det.loc[det.sensor == s, "cell_id"]) for s in ("MODIS", "VIIRS")}
    raw_days = {s: sorted(det.loc[det.sensor == s, "date"].unique()) for s in ("MODIS", "VIIRS")}
    first = det.sort_values("time").groupby("sensor").first()
    first_local = {s: pd.Timestamp(first.loc[s, "time"]).tz_localize("UTC").tz_convert(TZ) for s in first.index}

    # Harmonized: which sensors ever saw each cell
    ever = rec.groupby("cell_id").agg(lat=("lat", "mean"), lon=("lon", "mean"),
                                      m=("n_modis", "sum"), v=("n_viirs", "sum"),
                                      first_date=("date", "min"))
    ever["source"] = np.select([(ever.m > 0) & (ever.v > 0), ever.m > 0], ["MODIS+VIIRS", "MODIS"], "VIIRS")
    ci = ever.index.str.split("_").map(lambda p: (int(p[0]), int(p[1])))
    ever["geometry"] = [box(j * CELL, i * CELL, (j + 1) * CELL, (i + 1) * CELL) for i, j in ci]
    cells = gpd.GeoDataFrame(ever.reset_index(), geometry="geometry", crs=4326)

    daily = rec.groupby(["date", "source"]).size().unstack(fill_value=0) \
               .reindex(columns=["MODIS", "MODIS+VIIRS", "VIIRS"], fill_value=0)
    daily.index = pd.to_datetime(daily.index)
    daily = daily.reindex(pd.date_range(START, END), fill_value=0)
    first_harm = rec.sort_values("first_utc").iloc[0]
    viirs_gap = ("2024-07-24", "2024-07-28")
    n_area_cells = sum(1 for i in range(int(area.bounds[1] / CELL), int(area.bounds[3] / CELL) + 1)
                       for j in range(int(np.floor(area.bounds[0] / CELL)), int(np.floor(area.bounds[2] / CELL)) + 1)
                       if area.contains(box(j * CELL, i * CELL, (j + 1) * CELL, (i + 1) * CELL).centroid))

    stats = {
        "fire": f"{FIRE} Fire", "year": YEAR, "acres": round(float(fire.acres.iloc[0])),
        "cal_fire_alarm_date": fire.p_start.iloc[0].strftime("%Y-%m-%d"),
        "window": [START, END],
        "first_detection_local": {s: t.strftime("%Y-%m-%d %H:%M %Z") for s, t in first_local.items()},
        "first_detection_satellite": {s: str(first.loc[s, "satellite"]) for s in first.index},
        "viirs_no_data": list(viirs_gap),
        "days_with_detections": {"raw_modis": len(raw_days["MODIS"]), "raw_viirs": len(raw_days["VIIRS"]),
                                 "harmonized": int(rec.date.nunique())},
        "cells_inside_perimeter": n_area_cells,
        "cells_seen": {"raw_modis": len(raw_cells["MODIS"]), "raw_viirs": len(raw_cells["VIIRS"]),
                       "harmonized": int(len(ever))},
        "cells_by_source": ever.source.value_counts().to_dict(),
        "cells_only_harmonized_vs_viirs": int(len(set(ever.index) - raw_cells["VIIRS"])),
        "cells_only_harmonized_vs_modis": int(len(set(ever.index) - raw_cells["MODIS"])),
        "first_week_cells": {"raw_viirs": int(det[(det.sensor == "VIIRS") & (det.date <= "2024-07-30")].cell_id.nunique()),
                             "harmonized": int(rec[rec.date <= "2024-07-30"].cell_id.nunique())},
        "late_days_viirs_only": [d.strftime("%Y-%m-%d") for d, r in daily.iterrows()
                                 if r["VIIRS"] > 0 and r["MODIS"] == 0 and r["MODIS+VIIRS"] == 0],
        "daily_cells": {d.strftime("%Y-%m-%d"): {k: int(v) for k, v in r.items()} for d, r in daily.iterrows()},
    }
    (HARM_OUT / "park_fire.json").write_text(json.dumps(stats, indent=2))
    cells[["cell_id", "source", "first_date", "geometry"]].to_file(HARM_OUT / "park_fire_cells.geojson", driver="GeoJSON",
                                                                 COORDINATE_PRECISION=4)
    plot(fire, cells, daily, stats, first_local, viirs_gap)
    print(json.dumps({k: v for k, v in stats.items() if k != "daily_cells"}, indent=1))


def plot(fire, cells, daily, stats, first_local, viirs_gap) -> None:
    plt.rcParams.update({"font.family": "DejaVu Sans", "text.color": INK})
    fig = plt.figure(figsize=(12, 6.2), dpi=200, facecolor=SURFACE)
    gs = fig.add_gridspec(1, 2, width_ratios=[1, 1.35], wspace=0.12)

    # Map
    ax = fig.add_subplot(gs[0]); ax.set_facecolor(SURFACE)
    c = cells.to_crs(3310)
    for s in ("MODIS", "MODIS+VIIRS", "VIIRS"):
        part = c[c.source == s]
        if len(part):
            part.plot(ax=ax, color=COLORS[s], edgecolor=SURFACE, linewidth=0.25)
    fire.to_crs(3310).boundary.plot(ax=ax, color=INK, linewidth=0.9)
    ax.set_axis_off(); ax.set_aspect("equal")
    ax.set_title("Where each sensor saw fire", loc="left", fontsize=13, fontweight="bold", color=INK, pad=22)
    ax.text(0, 1.015, "~1 km cells, 24 Jul - 20 Aug 2024; white line = CAL FIRE perimeter",
            transform=ax.transAxes, fontsize=9, color=INK2, va="bottom")
    cs = stats["cells_seen"]
    ax.legend(handles=[Patch(color=COLORS[s], label=f"{LABELS[s]} ({stats['cells_by_source'].get(s, 0):,})")
                       for s in ("MODIS", "MODIS+VIIRS", "VIIRS")],
              loc="center left", bbox_to_anchor=(0.66, 0.3), frameon=False, fontsize=9.5, labelcolor=INK2)
    x0, x1 = ax.get_xlim(); y0, y1 = ax.get_ylim()
    ax.plot([x1 - 20000, x1], [y0 + 2000] * 2, color=INK3, lw=1.5)
    ax.text(x1 - 10000, y0 + 3500, "20 km", color=INK3, fontsize=8.5, ha="center")

    # Timeline
    tx = fig.add_subplot(gs[1]); tx.set_facecolor(SURFACE)
    g0, g1 = pd.Timestamp(viirs_gap[0]) - pd.Timedelta(hours=12), pd.Timestamp(viirs_gap[1]) + pd.Timedelta(hours=12)
    tx.axvspan(g0, g1, color="#ffffff", alpha=0.06, linewidth=0)
    tx.text(g0 + pd.Timedelta(hours=40), 590, "Suomi NPP VIIRS\nhas no data", color=INK2, fontsize=9, va="top")
    bottom = np.zeros(len(daily))
    for s in ("MODIS", "MODIS+VIIRS", "VIIRS"):
        tx.bar(daily.index, daily[s], 0.8, bottom=bottom, color=COLORS[s], label=LABELS[s],
               edgecolor=SURFACE, linewidth=0.6)
        bottom += daily[s].values
    t = first_local["MODIS"]
    tx.text(pd.Timestamp("2024-07-24"), daily.iloc[0].sum() + 12, f"First seen {t:%-d %b %H:%M} PDT, Aqua MODIS",
            rotation=90, ha="center", va="bottom", color=INK, fontsize=9)
    tv = first_local["VIIRS"]
    tx.annotate(f"VIIRS alone: first seen {tv:%-d %b}", xy=(pd.Timestamp("2024-07-29"), daily.loc["2024-07-29"].sum()),
                xytext=(pd.Timestamp("2024-08-04"), 330), color=INK, fontsize=9.5,
                arrowprops=dict(arrowstyle="-", color=INK3, lw=0.8))
    tx.annotate("Only VIIRS still sees\nthe smouldering edges", xy=(pd.Timestamp("2024-08-10"), 26),
                xytext=(pd.Timestamp("2024-08-11"), 170), color=INK, fontsize=9.5,
                arrowprops=dict(arrowstyle="-", color=INK3, lw=0.8))
    tx.set_ylim(0, 600)
    tx.xaxis.set_major_locator(mdates.WeekdayLocator(byweekday=mdates.WE))
    tx.xaxis.set_major_formatter(mdates.DateFormatter("%-d %b"))
    tx.tick_params(colors=INK3, length=0, labelsize=9)
    tx.grid(axis="y", color=RULE, linewidth=0.8); tx.set_axisbelow(True)
    for s in tx.spines.values():
        s.set_visible(False)
    tx.axhline(0, color=INK3, linewidth=0.8)
    tx.set_title("Fire cells per day in the harmonized record", loc="left", fontsize=13, fontweight="bold", color=INK, pad=22)
    tx.text(0, 1.015, "Stacked by which sensor saw each cell that day", transform=tx.transAxes, fontsize=9, color=INK2, va="bottom")
    tx.legend(loc="upper right", frameon=False, fontsize=9.5, labelcolor=INK2)

    fig.suptitle(f"Park Fire 2024: VIIRS alone missed its first five days; harmonized, it is seen from the first afternoon",
                 x=0.01, ha="left", fontsize=14, fontweight="bold", color=INK, y=0.995)
    fig.text(0.01, 0.015, f"Cells seen: harmonized {cs['harmonized']:,}, raw MODIS alone {cs['raw_modis']:,}, raw VIIRS alone "
             f"{cs['raw_viirs']:,}. Data: NASA FIRMS (MODIS C6.1, VIIRS S-NPP 375 m), CAL FIRE FRAP.",
             fontsize=8.5, color=INK3)
    fig.subplots_adjust(left=0.01, right=0.99, top=0.85, bottom=0.1)
    fig.savefig(HARM_OUT / "park_fire.png", facecolor=SURFACE)
    print(f"wrote {HARM_OUT / 'park_fire.png'}")


if __name__ == "__main__":
    main()
