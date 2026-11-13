"""Harmonize MODIS and VIIRS hotspots into one daily California fire record.

Pipeline for one year:
  1. Load MODIS (Terra + Aqua, 1 km) and VIIRS (Suomi NPP, 375 m) from the FIRMS yearly files,
     clipped to California, on the shared schema from train_rf.load_sensor.
  2. Score every detection with the shipped v3 classifier (MyApp/ML/ember_rf.bin with the
     land-cover / burn-history grid MyApp/ML/ember_static.bin, cutoff 0.60), exactly as the app
     does, and drop the ones it calls false alarms (farm burns, industrial heat, noise).
  3. Match detections across sensors. A MODIS and a VIIRS detection are the same fire when
       - distance: their pixel footprints touch, i.e. the centers are within half of each pixel's
         diagonal added together (MODIS pixels grow from 1 km at nadir to ~2 x 4.8 km at the scan
         edge, so a fixed radius is wrong at one end or the other), with at least 1 km;
       - time: they were observed within 6 hours of each other (Terra 10:30, Aqua and S-NPP
         13:30 local, and the night passes, without pairing a day pass with a night pass);
       - confidence: at least one of the two is nominal or high. Two low-confidence detections
         do not confirm each other.
  4. Roll the kept detections into one record per ~1 km cell (0.01 deg, the grid the
     classifier's static features use) per Pacific-time day, with a `source` column:
     MODIS, VIIRS or MODIS+VIIRS.

No API key needed: everything comes from fetch_data.py (FIRMS archive files, CAL FIRE, Census).

Run:  uv run --project ml python ml/harmonize.py 2024 2025
Writes ml/outputs/harmonized/harmonized_fires_{YEAR}.csv  (the daily harmonized record)
       ml/data/harmonized/detections_{YEAR}.parquet       (every detection with its score and match)
"""

from __future__ import annotations

import argparse
import struct
import zlib
from pathlib import Path

import geopandas as gpd
import numpy as np
import pandas as pd
from sklearn.neighbors import BallTree

from build_static_grids import BANDS, LAT0, LON0, STEP, lookup
from export_app_model import predict_like_swift
from train_rf import EARTH_KM, OUT, RAW, ROOT, load_sensor
from train_v3 import BIN, X, context_features

STATIC_BIN = ROOT.parent / "MyApp" / "ML" / "ember_static.bin"
THRESHOLD = float((OUT / "swift_threshold.txt").read_text())   # 0.60, chosen on 2020 only
HARM_OUT = OUT / "harmonized"
DET_OUT = ROOT / "data" / "harmonized"
TZ = "America/Los_Angeles"
CELL = 0.01

# Matching rules (see module docstring)
WINDOW_H = 6.0
MIN_RADIUS_KM = 1.0
MAX_RADIUS_KM = 5.0


# --------------------------------------------------------------------------- #
# 1. Load
# --------------------------------------------------------------------------- #
def load_static() -> dict[str, np.ndarray]:
    """Read the land-cover / burn-history grids from the app's bundle (no NLCD download needed).
    Format (build_static_grids.write_app_bin): 'EMSG', u32 version, rows, cols, bands,
    f64 lat0, lon0, step, then raw DEFLATE of uint8 bands, band-major."""
    data = STATIC_BIN.read_bytes()
    assert data[:4] == b"EMSG", "not an Ember static grid file"
    _, rows, cols, nb, lat0, lon0, step = struct.unpack_from("<IIII3d", data, 4)
    assert (lat0, lon0, step) == (LAT0, LON0, STEP) and nb == len(BANDS)
    raw = np.frombuffer(zlib.decompress(data[4 + 16 + 24:], -15), np.uint8).reshape(nb, rows, cols)
    return {b: raw[i] for i, b in enumerate(BANDS)}


def load_year(year: int) -> pd.DataFrame:
    """train_rf.load_year, but keeping the satellite name (Terra / Aqua / N) and FIRMS type."""
    parts = []
    for sensor, name in (("MODIS", "modis"), ("VIIRS", "viirs")):
        path = RAW / "firms" / f"{name}_{year}.csv"
        raw = pd.read_csv(path, usecols=["satellite"])
        d = load_sensor(path, sensor)
        sat = raw["satellite"].astype(str)
        d["satellite"] = sat.replace({"N": "Suomi NPP", "1": "NOAA-20", "N20": "NOAA-20"}).values
        parts.append(d)
    df = pd.concat(parts, ignore_index=True)
    df = df[df["time"].dt.year == year]
    ca = gpd.read_file(RAW / "boundary" / "california.geojson").to_crs(4326).union_all()
    inside = gpd.GeoSeries(gpd.points_from_xy(df["lon"], df["lat"]), crs=4326).within(ca).values
    df = df[inside].sort_values("time").reset_index(drop=True)
    df["delta_t"] = df["bright_mir"] - df["bright_tir"]
    df["pixel_area_km2"] = df["scan"] * df["track"]
    df["frp_density"] = df["frp"] / df["pixel_area_km2"]
    df["log_frp"] = np.log1p(df["frp"].clip(lower=0))
    df["month"] = df["time"].dt.month
    df["hour_utc"] = df["time"].dt.hour + df["time"].dt.minute / 60
    df["day"] = df["time"].dt.floor("D")
    return df


# --------------------------------------------------------------------------- #
# 2. Classify (the shipped model, unchanged)
# --------------------------------------------------------------------------- #
def classify(df: pd.DataFrame, grids: dict[str, np.ndarray]) -> pd.DataFrame:
    keep = [c for c in df.columns if c not in BANDS]
    feats = context_features(df[keep])
    feats = pd.concat([feats, lookup(grids, feats.lat.values, feats.lon.values)], axis=1)
    feats["wildfire_prob"] = predict_like_swift(BIN, X(feats))
    feats["is_wildfire"] = feats["wildfire_prob"] >= THRESHOLD
    return feats


# --------------------------------------------------------------------------- #
# 3. Cross-sensor matching
# --------------------------------------------------------------------------- #
def half_diag_km(df: pd.DataFrame) -> np.ndarray:
    return 0.5 * np.hypot(df["scan"].values, df["track"].values)


def match(df: pd.DataFrame, window_h: float = WINDOW_H, radius_km: float | None = None,
          use_confidence: bool = True) -> pd.DataFrame:
    """For every detection: does the other sensor have a matching detection? Adds `matched`,
    `match_dist_km` (to the nearest match) and `match_dt_h` (time to the nearest match in time).
    radius_km=None uses footprint-aware radii; a number uses that fixed radius (sensitivity runs)."""
    df = df.reset_index(drop=True)
    n = len(df)
    matched, mdist, mdt = np.zeros(n, bool), np.full(n, np.inf), np.full(n, np.inf)
    m_idx = np.flatnonzero(df["sensor"].values == "MODIS")
    v_idx = np.flatnonzero(df["sensor"].values == "VIIRS")
    t = df["time"].values.astype("datetime64[m]").astype(np.int64) / 60.0   # hours
    conf = df["conf_class"].fillna(0).values
    hd = half_diag_km(df)
    lat_r, lon_r = np.radians(df["lat"].values), np.radians(df["lon"].values)
    day = df["day"].values
    max_r = MAX_RADIUS_KM if radius_km is None else radius_km
    for d in (np.unique(day[m_idx]) if len(v_idx) else []):
        mi = m_idx[day[m_idx] == d]
        vi = v_idx[(day[v_idx] >= d - np.timedelta64(1, "D")) & (day[v_idx] <= d + np.timedelta64(1, "D"))]
        if not len(vi):
            continue
        tree = BallTree(np.c_[lat_r[vi], lon_r[vi]], metric="haversine")
        hits, dists = tree.query_radius(np.c_[lat_r[mi], lon_r[mi]], r=max_r / EARTH_KM, return_distance=True)
        for a, h, dist in zip(mi, hits, dists):
            if not len(h):
                continue
            b, dk = vi[h], dist * EARTH_KM
            dt = np.abs(t[b] - t[a])
            ok = dt <= window_h
            if radius_km is None:
                ok &= dk <= np.clip(hd[a] + hd[b], MIN_RADIUS_KM, MAX_RADIUS_KM)
            if use_confidence:
                ok &= np.maximum(conf[a], conf[b]) >= 1
            if not ok.any():
                continue
            b, dk, dt = b[ok], dk[ok], dt[ok]
            matched[a] = True
            mdist[a], mdt[a] = min(mdist[a], dk.min()), min(mdt[a], dt.min())
            matched[b] = True
            mdist[b], mdt[b] = np.fmin(mdist[b], dk), np.fmin(mdt[b], dt)
    out = pd.DataFrame({"matched": matched, "match_dist_km": mdist, "match_dt_h": mdt})
    out.loc[~matched, ["match_dist_km", "match_dt_h"]] = np.nan
    return out


# --------------------------------------------------------------------------- #
# 4. Daily harmonized record
# --------------------------------------------------------------------------- #
def cell_of(lat, lon) -> tuple[np.ndarray, np.ndarray]:
    return np.floor(np.asarray(lat) / CELL).astype(int), np.floor(np.asarray(lon) / CELL).astype(int)


def daily_record(det: pd.DataFrame) -> pd.DataFrame:
    """One row per ~1 km cell per Pacific-time day, from detections the classifier kept."""
    d = det[det["is_wildfire"]].copy()
    d["date"] = d["time"].dt.tz_localize("UTC").dt.tz_convert(TZ).dt.strftime("%Y-%m-%d")
    d["ci"], d["cj"] = cell_of(d.lat, d.lon)
    d["is_modis"] = d["sensor"] == "MODIS"
    d["is_viirs_"] = d["sensor"] == "VIIRS"
    d["frp_m"] = d["frp"].where(d["is_modis"])
    d["frp_v"] = d["frp"].where(d["is_viirs_"])
    d["night"] = d["is_day"] == 0
    g = d.groupby(["date", "ci", "cj"], sort=True)
    rec = g.agg(lat=("lat", "mean"), lon=("lon", "mean"),
                n_modis=("is_modis", "sum"), n_viirs=("is_viirs_", "sum"),
                cross_confirmed=("matched", "any"),
                frp_max_modis=("frp_m", "max"), frp_max_viirs=("frp_v", "max"),
                conf_max=("conf_class", "max"), wildfire_prob=("wildfire_prob", "max"),
                any_night=("night", "any"), any_day=("is_day", "max"),
                first_utc=("time", "min"), last_utc=("time", "max"),
                satellites=("satellite", lambda s: "+".join(sorted(set(s))))).reset_index()
    rec["source"] = np.select([(rec.n_modis > 0) & (rec.n_viirs > 0), rec.n_modis > 0],
                              ["MODIS+VIIRS", "MODIS"], "VIIRS")
    # Harmonized confidence: high if the other sensor confirmed it or either sensor said high
    conf = rec["conf_max"].fillna(0).astype(int)
    conf = np.where(rec["cross_confirmed"], 2, conf)
    rec["confidence"] = pd.Series(conf).map({0: "low", 1: "nominal", 2: "high"}).values
    rec["daynight"] = np.select([(rec.any_day == 1) & rec.any_night, rec.any_night], ["DN", "N"], "D")
    rec["cell_id"] = rec.ci.astype(str) + "_" + rec.cj.astype(str)
    for c in ("first_utc", "last_utc"):
        rec[c] = rec[c].dt.strftime("%Y-%m-%dT%H:%MZ")
    rec["lat"], rec["lon"] = rec.lat.round(4), rec.lon.round(4)
    rec["wildfire_prob"] = rec.wildfire_prob.round(3)
    cols = ["date", "cell_id", "lat", "lon", "source", "cross_confirmed", "confidence", "n_modis", "n_viirs",
            "satellites", "frp_max_modis", "frp_max_viirs", "wildfire_prob", "daynight", "first_utc", "last_utc"]
    return rec[cols]


# --------------------------------------------------------------------------- #
def harmonize_year(year: int, grids: dict[str, np.ndarray]) -> pd.DataFrame:
    DET_OUT.mkdir(parents=True, exist_ok=True)
    cache = DET_OUT / f"detections_{year}.parquet"
    if cache.exists():
        det = pd.read_parquet(cache)
    else:
        raw = load_year(year)
        print(f"[{year}] {len(raw):,} detections in California "
              f"(MODIS {int((raw.sensor == 'MODIS').sum()):,}, VIIRS {int((raw.sensor == 'VIIRS').sum()):,}); scoring")
        det = classify(raw, grids)
        det["satellite"] = raw["satellite"].values
        print(f"[{year}] classifier keeps {det.is_wildfire.mean():.1%}; matching across sensors")
        kept = det[det.is_wildfire]
        m_all = match(det)                              # raw: every detection
        m_kept = match(kept).set_index(kept.index)      # after dropping false alarms
        det["matched_raw"] = m_all["matched"].values
        det["matched"] = False
        det.loc[kept.index, "matched"] = m_kept["matched"].values
        det.loc[kept.index, "match_dist_km"] = m_kept["match_dist_km"].values
        det.loc[kept.index, "match_dt_h"] = m_kept["match_dt_h"].values
        det.to_parquet(cache)
    rec = daily_record(det)
    HARM_OUT.mkdir(parents=True, exist_ok=True)
    path = HARM_OUT / f"harmonized_fires_{year}.csv"
    rec.to_csv(path, index=False)
    print(f"[{year}] {path.relative_to(ROOT.parent)}: {len(rec):,} fire cell-days on {rec.date.nunique()} days; "
          f"source {rec.source.value_counts().to_dict()}")
    return rec


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("years", type=int, nargs="+")
    args = ap.parse_args()
    grids = load_static()
    for y in args.years:
        harmonize_year(y, grids)


if __name__ == "__main__":
    main()
