"""Stress test the shipped v3 model (MyApp/ML/ember_rf.bin) on data and conditions it never saw.

Scenarios (all scored with the exported forest, exactly as the app runs it):
  1. New years: California 2022 and 2023, which were quiet fire years, unlike 2020/2021.
  2. Satellite swap: 2023 with NOAA-20 VIIRS in place of Suomi NPP (the app's default satellite).
  3. Sensor loss: only VIIRS (MODIS retired) or only MODIS available.
  4. No static context: land cover and burn history blank (what happens outside California).
  5. Noisy inputs: +-15 % FRP and brightness noise, plus ~500 m geolocation jitter.
  6. App-style windows: features computed in 3-day downloads (1 context day + 2 shown),
     the way the app sees data, instead of over the whole year at once.

Needs: fetch_data.py 2022 2023 (and --noaa20 2023), build_static_grids.py, train_v3.py.
Run:   uv run --project ml python ml/stress_test.py
"""

from __future__ import annotations

import json

import numpy as np
import pandas as pd
from sklearn.metrics import roc_auc_score

from build_static_grids import BANDS, load_grids, lookup
from export_app_model import predict_like_swift
from small_fires import label_buffered
from train_rf import OUT, RAW, load_year
from train_v3 import BIN, FEATURES, X, context_features, fire_report

THRESHOLD = float((OUT / "swift_threshold.txt").read_text())
GRIDS = load_grids()


def prepare(year: int, viirs_file: str | None = None, sensors=("MODIS", "VIIRS")) -> pd.DataFrame:
    df = load_year(year, viirs_file, sensors)
    df = label_buffered(df, year)
    cols = ["lat", "lon", "time", "day", "sensor", "label", "fire_name", "is_viirs", "bright_mir", "bright_tir",
            "delta_t", "frp", "log_frp", "frp_density", "pixel_area_km2", "conf_class", "is_day", "hour_utc",
            "month", "scan", "track"]
    return with_features(df[cols])


def with_features(df: pd.DataFrame) -> pd.DataFrame:
    df = context_features(df)
    return pd.concat([df, lookup(GRIDS, df.lat.values, df.lon.values)], axis=1)


def score(df: pd.DataFrame) -> np.ndarray:
    return predict_like_swift(BIN, X(df))


def summarize(name: str, df: pd.DataFrame, prob: np.ndarray) -> dict:
    r = fire_report(df, prob >= THRESHOLD)
    y = df.label.values
    r["auc"] = roc_auc_score(y, prob) if 0 < y.sum() < len(y) else float("nan")
    r["n"], r["wildfire_share"] = len(df), float(y.mean())
    base = fire_report(df, np.ones(len(df), bool))
    r["all_fire_baseline_accuracy"] = base["accuracy"]
    print(f"{name:<38} n {len(df):>7,}  wildfire {y.mean():5.1%}  acc {r['accuracy']:.3f} (always-fire {base['accuracy']:.3f})  "
          f"recall {r['recall']:.3f}  precision {r['precision']:.3f}  removed {r['nonfire_removed']:.3f}  "
          f"auc {r['auc']:.3f}  fires {r['fires_caught']}/{r['fires']} {r['by_size']}")
    return r


def perturb(df: pd.DataFrame, seed: int = 0) -> pd.DataFrame:
    rng = np.random.default_rng(seed)
    d = df.copy()
    k = lambda: rng.normal(1, 0.15, len(d)).clip(0.5, 1.5)
    d["frp"] = d["frp"] * k()
    d["bright_mir"] = d["bright_mir"] * rng.normal(1, 0.02, len(d))   # ~6 K at 300 K
    d["bright_tir"] = d["bright_tir"] * rng.normal(1, 0.02, len(d))
    d["lat"] = d["lat"] + rng.normal(0, 0.0045, len(d))                 # ~500 m
    d["lon"] = d["lon"] + rng.normal(0, 0.0055, len(d))
    d["delta_t"] = d["bright_mir"] - d["bright_tir"]
    d["log_frp"] = np.log1p(d["frp"].clip(lower=0))
    d["frp_density"] = d["frp"] / d["pixel_area_km2"]
    base = [c for c in d.columns if c not in BANDS and not c.startswith(("n_", "maxfrp_", "sumfrp_", "cross_"))]
    return with_features(d[base])


def app_windows(df: pd.DataFrame) -> np.ndarray:
    """Score the year the way the app downloads it: 2 shown days plus 1 context day before."""
    base = [c for c in df.columns if c not in BANDS and not c.startswith(("n_", "maxfrp_", "sumfrp_", "cross_"))]
    prob = np.full(len(df), np.nan)
    days = np.sort(df.day.unique())
    for start in pd.date_range(days[0], days[-1], freq="2D"):
        shown = (df.day >= start) & (df.day < start + pd.Timedelta(days=2))
        if not shown.any():
            continue
        window = (df.day >= start - pd.Timedelta(days=1)) & (df.day < start + pd.Timedelta(days=2))
        sub = with_features(df.loc[window, base].reset_index())
        p = score(sub)
        keep = (sub.day >= start).values
        prob[sub.loc[keep, "index"].values] = p[keep]
    return prob


def main() -> None:
    res = {}
    print(f"model: {BIN.name}, cutoff {THRESHOLD}\n--- 1. new years ---")
    data = {y: prepare(y) for y in (2021, 2022, 2023)}
    for y, d in data.items():
        res[f"{y}"] = summarize(f"{y} (MODIS + S-NPP VIIRS)", d, score(d))

    print("--- 2. satellite swap ---")
    if (RAW / "firms" / "viirs_noaa20_sp_2023.csv").exists():
        n20 = prepare(2023, viirs_file="viirs_noaa20_sp_2023.csv")
        res["2023_noaa20"] = summarize("2023 (MODIS + NOAA-20 VIIRS)", n20, score(n20))
    else:
        print("skipped: run fetch_data.py --noaa20 2023")

    print("--- 3. sensor loss ---")
    for y in (2021, 2023):
        for only in ("VIIRS", "MODIS"):
            d = prepare(y, sensors=(only,))
            res[f"{y}_{only}_only"] = summarize(f"{y} {only} only (other sensor gone)", d, score(d))

    print("--- 4. no land cover / burn history ---")
    for y in (2021, 2023):
        d = data[y].assign(**{b: np.nan for b in BANDS})
        res[f"{y}_no_static"] = summarize(f"{y} without static grids", d, score(d))

    print("--- 5. noisy inputs ---")
    for y in (2021, 2023):
        d = perturb(data[y])
        res[f"{y}_noisy"] = summarize(f"{y} +-15% FRP, +-2% K, 500 m jitter", d, score(d))

    print("--- 6. app-style 3-day downloads ---")
    for y in (2023,):
        d = data[y]
        full, win = score(d), app_windows(d)
        same = np.mean((full >= THRESHOLD) == (win >= THRESHOLD))
        res[f"{y}_app_windows"] = summarize(f"{y} scored in app-style windows", d, win)
        res[f"{y}_app_windows"]["decisions_same_as_full_year"] = float(same)
        print(f"   decisions identical to whole-year scoring: {same:.4%} (max |dp| {np.nanmax(np.abs(full - win)):.1e})")

    (OUT / "stress_test.json").write_text(json.dumps(res, indent=2, default=float))
    print(f"\nwrote {OUT / 'stress_test.json'}")


if __name__ == "__main__":
    main()
