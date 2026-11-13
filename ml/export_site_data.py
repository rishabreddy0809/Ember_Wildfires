"""Pack the harmonized record and validation numbers for the website's fire calendar.

Run:  uv run --project ml python ml/export_site_data.py 2024 2025
Writes website/data/harmonized.json and copies the charts to website/img/.
"""

from __future__ import annotations

import argparse
import json
import shutil

import geopandas as gpd
import numpy as np
import pandas as pd

from harmonize import CELL, HARM_OUT
from train_rf import RAW, ROOT

SITE = ROOT.parent / "website"
SRC = {"MODIS": 0, "MODIS+VIIRS": 1, "VIIRS": 2}


def outline() -> list[list[list[float]]]:
    ca = gpd.read_file(RAW / "boundary" / "california.geojson").to_crs(4326).union_all().simplify(0.02)
    polys = getattr(ca, "geoms", [ca])
    return [[[round(x, 2), round(y, 2)] for x, y in p.exterior.coords] for p in polys if p.area > 0.01]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("years", type=int, nargs="+")
    years = ap.parse_args().years
    res = json.loads((HARM_OUT / "results.json").read_text())["years"]
    out = {"cell_deg": CELL, "outline": outline(), "sources": list(SRC), "years": {}}
    for y in years:
        rec = pd.read_csv(HARM_OUT / f"harmonized_fires_{y}.csv")
        ij = rec.cell_id.str.split("_", expand=True).astype(int)
        rec["i"], rec["j"], rec["s"] = ij[0], ij[1], rec.source.map(SRC)
        days = {}
        for d, g in rec.groupby("date"):
            days[d] = {"n": [int((g.s == k).sum()) for k in range(3)],
                       "c": g[["i", "j", "s"]].values.astype(int).ravel().tolist(),
                       "frp": round(float(np.nanmax(g[["frp_max_modis", "frp_max_viirs"]].values)), 1)}
        r = res[str(y)]
        gaps = {s: r["sensor_gaps"][s]["gaps_3_days_or_more"] for s in ("MODIS", "VIIRS")}
        out["years"][str(y)] = {"days": days, "gaps": gaps,
                                "match_before": r["match_rate"]["before_raw_overlay"]["all"],
                                "match_after": r["match_rate"]["after_harmonized"]["all"],
                                "overlap_before": r["cell_day_overlap"]["before_raw"]["jaccard"],
                                "overlap_after": r["cell_day_overlap"]["after_harmonized"]["jaccard"]}
    path = SITE / "data" / "harmonized.json"
    path.write_text(json.dumps(out, separators=(",", ":")))
    for f in ("agreement.png", "park_fire.png"):
        shutil.copy(HARM_OUT / f, SITE / "img" / f)
    print(f"wrote {path} ({path.stat().st_size / 1e3:.0f} kB) and website/img charts")


if __name__ == "__main__":
    main()
