"""How well do MODIS and VIIRS agree before and after harmonization, and what does the
harmonized record still miss?

Before = the raw FIRMS products overlaid as they are: every detection, compared on the same
         ~1 km cell and UTC day.
After  = the harmonized record (harmonize.py): false alarms dropped by the classifier, then
         matched by pixel footprint distance, a 6 h window and confidence.

Two headline metrics:
  1. Match rate: share of detections that the other sensor also saw.
  2. Cell-day overlap (Jaccard): of all ~1 km cell-days that either sensor reports as fire,
     the share that both report.

Checks against independent truth (CAL FIRE FRAP perimeters, a detection within one pixel of
a perimeter between 1 day before the alarm date and 2 days after containment):
  - fires seen by raw MODIS, raw VIIRS, and the harmonized record, by fire size;
  - large fires the harmonized record drops completely;
  - days a sensor has no data at all.

Run:  uv run --project ml python ml/validate.py 2024 2025     (after harmonize.py)
Writes ml/outputs/harmonized/results.json
"""

from __future__ import annotations

import argparse
import json

import geopandas as gpd
import numpy as np
import pandas as pd

from harmonize import DET_OUT, HARM_OUT, TZ, cell_of, match
from small_fires import BUFFER_M
from train_rf import OPEN_FIRE_DAYS, POST_DAYS, PRE_DAYS, RAW, _to_dt

SIZE_BUCKETS = [(0, 100), (100, 1000), (1000, 10000), (10000, 1e9)]   # acres
SENS_RADII = [1.0, 2.0, 4.0, None]                                     # None = footprint-aware
SENS_WINDOWS = [1.0, 6.0, 12.0]


# --------------------------------------------------------------------------- #
def perimeters(year: int) -> gpd.GeoDataFrame:
    g = gpd.read_file(RAW / "perimeters" / f"perimeters_{year}.geojson").to_crs(4326)
    g["p_start"] = _to_dt(g["ALARM_DATE"]).dt.floor("D")
    g["p_end"] = _to_dt(g["CONT_DATE"]).dt.floor("D")
    g = g[g.p_start.notna() & g.geometry.notna() & ~g.geometry.is_empty].copy()
    bad = g.p_end.isna() | (g.p_end < g.p_start)
    g.loc[bad, "p_end"] = g.loc[bad, "p_start"] + pd.Timedelta(days=OPEN_FIRE_DAYS)
    bad_geom = ~g.geometry.is_valid
    g.loc[bad_geom, "geometry"] = g.loc[bad_geom].geometry.make_valid(method="structure")
    g["fire_id"] = g["OBJECTID"].astype(int)
    g["name"] = g["FIRE_NAME"].fillna("UNNAMED").str.title()
    return g[["fire_id", "name", "GIS_ACRES", "p_start", "p_end", "geometry"]].rename(columns={"GIS_ACRES": "acres"})


def label(det: pd.DataFrame, perims: gpd.GeoDataFrame) -> pd.Series:
    """fire_id of the perimeter each detection belongs to (one pixel of tolerance), or NaN."""
    p = perims.to_crs(3310)
    pts = gpd.GeoDataFrame(det[["day", "sensor"]], geometry=gpd.points_from_xy(det.lon, det.lat), crs=4326).to_crs(3310)
    hits = []
    for s, b in BUFFER_M.items():
        pb = p.copy(); pb["geometry"] = pb.buffer(b)
        j = gpd.sjoin(pts[pts.sensor == s], pb, predicate="within", how="inner")
        hits.append(j[(j.day >= j.p_start - pd.Timedelta(days=PRE_DAYS)) & (j.day <= j.p_end + pd.Timedelta(days=POST_DAYS))])
    j = pd.concat(hits)
    j = j.sort_values("acres", ascending=False)          # overlapping perimeters: credit the larger fire
    j = j[~j.index.duplicated()]
    return pd.Series(j["fire_id"], index=j.index).reindex(det.index)


# --------------------------------------------------------------------------- #
def match_rate(df: pd.DataFrame, matched: np.ndarray) -> dict:
    m = df.sensor.values == "MODIS"
    return {"all": float(matched.mean()), "modis_seen_by_viirs": float(matched[m].mean()),
            "viirs_seen_by_modis": float(matched[~m].mean()), "n_detections": int(len(df))}


def naive_match(df: pd.DataFrame) -> np.ndarray:
    """Raw overlay: matched if the other sensor has a detection in the same 0.01 deg cell and UTC day."""
    ci, cj = cell_of(df.lat, df.lon)
    key = pd.Series(list(zip(df.day.values, ci, cj)), index=df.index)
    is_m = df.sensor.values == "MODIS"
    mk, vk = set(key[is_m]), set(key[~is_m])
    return np.where(is_m, key.isin(vk).values, key.isin(mk).values)


def cell_days(df: pd.DataFrame) -> pd.DataFrame:
    d = df.assign(date=df.time.dt.tz_localize("UTC").dt.tz_convert(TZ).dt.date)
    d["ci"], d["cj"] = cell_of(d.lat, d.lon)
    return d.groupby(["date", "ci", "cj"]).sensor.agg(lambda s: frozenset(s)).reset_index()


def overlap(df: pd.DataFrame) -> dict:
    c = cell_days(df)
    both = int(c.sensor.map(len).eq(2).sum())
    daily = c.assign(m=c.sensor.map(lambda s: "MODIS" in s), v=c.sensor.map(lambda s: "VIIRS" in s)) \
             .groupby("date")[["m", "v"]].sum()
    r = float(np.corrcoef(daily.m, daily.v)[0, 1]) if len(daily) > 2 else float("nan")
    return {"jaccard": both / len(c), "cell_days_both": both, "cell_days_either": int(len(c)),
            "cell_days_modis_only": int(c.sensor.map(lambda s: s == {"MODIS"}).sum()),
            "cell_days_viirs_only": int(c.sensor.map(lambda s: s == {"VIIRS"}).sum()),
            "daily_count_pearson_r": r}


def fire_coverage(det: pd.DataFrame, perims: gpd.GeoDataFrame) -> dict:
    """Fires (perimeters) seen at least once, by size: raw MODIS, raw VIIRS, harmonized."""
    f = perims.set_index("fire_id")
    seen = {
        "raw_modis": set(det.loc[det.sensor.eq("MODIS") & det.fire_id.notna(), "fire_id"]),
        "raw_viirs": set(det.loc[det.sensor.eq("VIIRS") & det.fire_id.notna(), "fire_id"]),
        "raw_either": set(det.loc[det.fire_id.notna(), "fire_id"]),
        "harmonized": set(det.loc[det.is_wildfire & det.fire_id.notna(), "fire_id"]),
    }
    out = {}
    for lo, hi in SIZE_BUCKETS:
        ids = set(f.index[(f.acres >= lo) & (f.acres < hi)])
        name = f"{int(lo):,}-{int(hi):,} acres" if hi < 1e9 else f"{int(lo):,}+ acres"
        out[name] = {"fires": len(ids), **{k: len(ids & v) for k, v in seen.items()}}
    out["all"] = {"fires": len(f), **{k: len(set(f.index) & v) for k, v in seen.items()}}
    return out


def dropped_fires(det: pd.DataFrame, perims: gpd.GeoDataFrame, min_acres: float = 1000) -> list[dict]:
    """Fires that raw FIRMS saw but the harmonized record lost completely (classifier dropped all)."""
    lab = det[det.fire_id.notna()]
    g = lab.groupby("fire_id").agg(raw=("is_wildfire", "size"), kept=("is_wildfire", "sum"),
                                   prob=("wildfire_prob", "median"))
    g = g.join(perims.set_index("fire_id")[["name", "acres", "p_start"]])
    g = g[(g.kept == 0) & (g.acres >= min_acres)].sort_values("acres", ascending=False)
    return [{"fire": r.name, "acres": round(float(r.acres)), "start": r.p_start.strftime("%Y-%m-%d"),
             "raw_detections": int(r.raw), "median_wildfire_prob": round(float(r.prob), 3)}
            for r in g.itertuples(index=False)]


def sensor_gaps(det: pd.DataFrame, year: int) -> dict:
    days = pd.date_range(f"{year}-01-01", f"{year}-12-31")
    out = {}
    for s in ("MODIS", "VIIRS"):
        have = set(det.loc[det.sensor == s, "day"])
        empty = [d for d in days if d not in have]
        runs, start, prev = [], None, None
        for d in empty:
            if start is None or (d - prev).days > 1:
                if start is not None:
                    runs.append((start, prev))
                start = d
            prev = d
        if start is not None:
            runs.append((start, prev))
        out[s] = {"days_without_any_detection": len(empty),
                  "gaps_3_days_or_more": [f"{a:%Y-%m-%d} to {b:%Y-%m-%d}" for a, b in runs if (b - a).days >= 2]}
    return out


def sensitivity(kept: pd.DataFrame) -> list[dict]:
    rows = []
    for r in SENS_RADII:
        for w in SENS_WINDOWS:
            m = match(kept, window_h=w, radius_km=r)["matched"].values
            rows.append({"radius_km": "footprint" if r is None else r, "window_h": w, "match_rate": round(float(m.mean()), 4)})
    m = match(kept, use_confidence=False)["matched"].values
    rows.append({"radius_km": "footprint", "window_h": 6.0, "confidence_rule": False, "match_rate": round(float(m.mean()), 4)})
    return rows


# --------------------------------------------------------------------------- #
def validate_year(year: int) -> dict:
    det = pd.read_parquet(DET_OUT / f"detections_{year}.parquet")
    perims = perimeters(year)
    det["fire_id"] = label(det, perims)
    kept = det[det.is_wildfire]
    y = det.fire_id.notna().values
    pred = det.is_wildfire.values
    res = {
        "detections": {"raw": int(len(det)), "raw_modis": int((det.sensor == "MODIS").sum()),
                       "raw_viirs": int((det.sensor == "VIIRS").sum()), "kept_by_classifier": int(pred.sum())},
        "match_rate": {
            "before_raw_overlay": match_rate(det, naive_match(det)),
            "raw_with_matching_rules": match_rate(det, det.matched_raw.values),
            "after_harmonized": match_rate(kept, kept.matched.values),
        },
        "cell_day_overlap": {"before_raw": overlap(det), "after_harmonized": overlap(kept)},
        "classifier_vs_perimeters": {
            "perimeter_detections_kept": float(pred[y].mean()),
            "non_perimeter_detections_removed": float((~pred[~y]).mean()),
            "kept_inside_perimeters": float(y[pred].mean()),
            "raw_inside_perimeters": float(y.mean()),
        },
        "fires_seen": fire_coverage(det, perims),
        "large_fires_dropped_by_classifier": dropped_fires(det, perims),
        "sensor_gaps": sensor_gaps(det, year),
        "match_rate_sensitivity": sensitivity(kept),
    }
    rec = pd.read_csv(HARM_OUT / f"harmonized_fires_{year}.csv")
    res["harmonized_record"] = {"cell_days": int(len(rec)), "days_with_fire": int(rec.date.nunique()),
                                "by_source": rec.source.value_counts().to_dict(),
                                "cross_confirmed": int(rec.cross_confirmed.sum())}
    return res


def show(year: int, r: dict) -> None:
    mr, ov = r["match_rate"], r["cell_day_overlap"]
    print(f"\n=== {year} ===")
    for k, v in mr.items():
        print(f"match rate {k:<26} {v['all']:.1%}  (MODIS seen by VIIRS {v['modis_seen_by_viirs']:.1%}, "
              f"VIIRS seen by MODIS {v['viirs_seen_by_modis']:.1%}, n {v['n_detections']:,})")
    for k, v in ov.items():
        print(f"cell-day overlap {k:<17} {v['jaccard']:.1%}  ({v['cell_days_both']:,} of {v['cell_days_either']:,}); "
              f"daily count r {v['daily_count_pearson_r']:.2f}")
    print("fires seen:", json.dumps(r["fires_seen"]))
    print("classifier vs perimeters:", {k: round(v, 3) for k, v in r["classifier_vs_perimeters"].items()})
    print("large fires dropped:", [(f["fire"], f["acres"]) for f in r["large_fires_dropped_by_classifier"]])
    print("gaps:", r["sensor_gaps"])


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("years", type=int, nargs="+")
    years = ap.parse_args().years
    out = {"method": __doc__.split("Run:")[0].strip(), "years": {}}
    for y in years:
        out["years"][str(y)] = validate_year(y)
        show(y, out["years"][str(y)])
    path = HARM_OUT / "results.json"
    path.write_text(json.dumps(out, indent=2, default=str))
    print(f"\nwrote {path}")


if __name__ == "__main__":
    main()
