"""Random forest on harmonized MODIS + VIIRS fire detections.

Train on California 2020, test on California 2021.

Task: for every satellite fire detection, predict whether it belongs to a mapped
California wildfire (inside a CAL FIRE / NIFC perimeter, during that fire's
active dates) or not (agricultural / prescribed burns, industrial heat sources,
false alarms).

Run:  uv run --project ml python ml/train_rf.py
"""

from __future__ import annotations

import json
from pathlib import Path

import geopandas as gpd
import joblib
import numpy as np
import pandas as pd
from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import (
    accuracy_score,
    confusion_matrix,
    f1_score,
    precision_score,
    recall_score,
    roc_auc_score,
)
from sklearn.neighbors import BallTree

ROOT = Path(__file__).resolve().parent
RAW = ROOT / "data" / "raw"
OUT = ROOT / "outputs"
EARTH_KM = 6371.0
SEED = 42

# Days of slack around a perimeter's alarm/containment dates, and the active
# window assumed when a fire has no containment date.
PRE_DAYS, POST_DAYS, OPEN_FIRE_DAYS = 1, 2, 120


# --------------------------------------------------------------------------- #
# 1. Load and harmonize the two sensors onto one schema
# --------------------------------------------------------------------------- #
def _confidence_class(df: pd.DataFrame, sensor: str) -> pd.Series:
    """Common ordinal confidence: 0 = low, 1 = nominal, 2 = high.

    MODIS reports 0-100 %; the MODIS C6 user guide bins it as low < 30,
    nominal 30-79, high >= 80. VIIRS reports l / n / h directly.
    """
    c = df["confidence"]
    if sensor == "MODIS":
        c = pd.to_numeric(c, errors="coerce")
        return pd.cut(c, [-1, 29, 79, 101], labels=[0, 1, 2]).astype(float)
    return c.astype(str).str.lower().str[0].map({"l": 0, "n": 1, "h": 2}).astype(float)


def load_sensor(path: Path, sensor: str) -> pd.DataFrame:
    df = pd.read_csv(path)
    mir = "brightness" if sensor == "MODIS" else "bright_ti4"   # ~4 um channel
    tir = "bright_t31" if sensor == "MODIS" else "bright_ti5"   # ~11 um channel
    hhmm = df["acq_time"].astype(int)
    out = pd.DataFrame(
        {
            "lat": df["latitude"].astype(float),
            "lon": df["longitude"].astype(float),
            "time": pd.to_datetime(df["acq_date"])
            + pd.to_timedelta(hhmm // 100, unit="h")
            + pd.to_timedelta(hhmm % 100, unit="m"),
            "sensor": sensor,
            "is_viirs": int(sensor == "VIIRS"),
            "bright_mir": df[mir].astype(float),
            "bright_tir": df[tir].astype(float),
            "frp": df["frp"].astype(float),
            "scan": df["scan"].astype(float),
            "track": df["track"].astype(float),
            "is_day": (df["daynight"].astype(str).str.upper() == "D").astype(int),
            "conf_class": _confidence_class(df, sensor),
        }
    )
    if "type" in df.columns:  # 0 veg fire, 1 volcano, 2 static land source, 3 offshore
        out["firms_type"] = pd.to_numeric(df["type"], errors="coerce")
    return out


def load_year(year: int, viirs_file: str | None = None, sensors=("MODIS", "VIIRS")) -> pd.DataFrame:
    files = {"MODIS": f"modis_{year}.csv", "VIIRS": viirs_file or f"viirs_{year}.csv"}
    parts = [load_sensor(RAW / "firms" / files[s], s) for s in sensors]
    df = pd.concat(parts, ignore_index=True)
    df = df[df["time"].dt.year == year]
    # Keep California only: perimeters (labels) exist only for CA fires
    ca = gpd.read_file(RAW / "boundary" / "california.geojson").to_crs(4326).union_all()
    in_ca = gpd.GeoSeries(gpd.points_from_xy(df["lon"], df["lat"]), crs=4326).within(ca).values
    df = df[in_ca].sort_values("time").reset_index(drop=True)

    # Resolution-independent radiometric features
    df["delta_t"] = df["bright_mir"] - df["bright_tir"]
    df["pixel_area_km2"] = df["scan"] * df["track"]
    df["frp_density"] = df["frp"] / df["pixel_area_km2"]
    df["log_frp"] = np.log1p(df["frp"].clip(lower=0))
    df["month"] = df["time"].dt.month
    df["hour_utc"] = df["time"].dt.hour + df["time"].dt.minute / 60
    df["day"] = df["time"].dt.floor("D")
    return df


# --------------------------------------------------------------------------- #
# 2. Spatio-temporal context features (this is where the sensors are fused)
# --------------------------------------------------------------------------- #
def _count_neighbors(src: pd.DataFrame, ref: pd.DataFrame, radius_km: float,
                     day_lo: int, day_hi: int, exclude_self: bool) -> tuple[np.ndarray, np.ndarray]:
    """For each row of src, count rows of ref within radius_km whose day is in
    [day + day_lo, day + day_hi]. Also return the max FRP among those rows."""
    counts = np.zeros(len(src), dtype=np.int32)
    max_frp = np.zeros(len(src), dtype=np.float32)
    if ref.empty:
        return counts, max_frp
    ref_days = ref["day"].values
    src_days = src["day"].values
    for d in np.unique(src_days):
        lo, hi = d + np.timedelta64(day_lo, "D"), d + np.timedelta64(day_hi, "D")
        r = ref[(ref_days >= lo) & (ref_days <= hi)]
        if r.empty:
            continue
        s_idx = np.flatnonzero(src_days == d)
        tree = BallTree(np.radians(r[["lat", "lon"]].values), metric="haversine")
        q = np.radians(src.iloc[s_idx][["lat", "lon"]].values)
        hits = tree.query_radius(q, r=radius_km / EARTH_KM)
        r_frp = r["frp"].values
        for k, h in zip(s_idx, hits):
            n = len(h) - (1 if exclude_self else 0)
            counts[k] = max(n, 0)
            if len(h):
                max_frp[k] = r_frp[h].max()
    return counts, max_frp


def add_context_features(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()
    for sensor in ("MODIS", "VIIRS"):
        m = df["sensor"] == sensor
        same, other = df[m], df[~m]
        idx = df.index[m]

        # Same-sensor clustering on the same day (fire size / coherence)
        c, f = _count_neighbors(same, same, 2.0, 0, 0, exclude_self=True)
        df.loc[idx, "n_same_2km_0d"] = c
        # Cross-sensor corroboration: did the OTHER satellite see fire nearby?
        c, f = _count_neighbors(same, other, 2.0, -1, 1, exclude_self=False)
        df.loc[idx, "n_other_2km_1d"] = c
        df.loc[idx, "maxfrp_other_2km_1d"] = f

    # Both sensors together: cluster size today and persistence over prior days
    c, f = _count_neighbors(df, df, 5.0, 0, 0, exclude_self=True)
    df["n_all_5km_0d"], df["maxfrp_all_5km_0d"] = c, f
    c, _ = _count_neighbors(df, df, 5.0, -3, -1, exclude_self=False)
    df["n_all_5km_prev3d"] = c
    c, _ = _count_neighbors(df, df, 1.0, -365, -30, exclude_self=False)
    df["n_all_1km_prev30_365d"] = c   # persistent site (refinery, plant, ...)
    df["cross_sensor_confirmed"] = (df["n_other_2km_1d"] > 0).astype(int)
    return df


# --------------------------------------------------------------------------- #
# 3. Labels from fire perimeters
# --------------------------------------------------------------------------- #
DATE_CANDIDATES = {
    "start": ["ALARM_DATE", "alarm_date", "poly_DateCurrent", "attr_FireDiscoveryDateTime",
              "DISCOVERY_DATE", "FireDiscoveryDateTime", "start_date"],
    "end": ["CONT_DATE", "cont_date", "attr_ContainmentDateTime", "ContainmentDateTime",
            "CONTAINMENT_DATE", "end_date"],
    "name": ["FIRE_NAME", "fire_name", "poly_IncidentName", "attr_IncidentName",
             "IncidentName", "INCIDENT", "name"],
}


def _pick(cols, options):
    for o in options:
        if o in cols:
            return o
    return None


def _to_dt(s: pd.Series) -> pd.Series:
    if pd.api.types.is_numeric_dtype(s):
        return pd.to_datetime(s, unit="ms", errors="coerce").dt.tz_localize(None)
    return pd.to_datetime(s, errors="coerce", utc=True).dt.tz_localize(None)


def load_perimeters(year: int) -> gpd.GeoDataFrame:
    gdf = gpd.read_file(RAW / "perimeters" / f"perimeters_{year}.geojson").to_crs(4326)
    s = _pick(gdf.columns, DATE_CANDIDATES["start"])
    e = _pick(gdf.columns, DATE_CANDIDATES["end"])
    n = _pick(gdf.columns, DATE_CANDIDATES["name"])
    assert s, f"no start-date column in perimeters_{year}: {list(gdf.columns)}"
    gdf["p_start"] = _to_dt(gdf[s]).dt.floor("D")
    gdf["p_end"] = _to_dt(gdf[e]).dt.floor("D") if e else pd.NaT
    gdf["p_name"] = gdf[n].astype(str) if n else gdf.index.astype(str)
    gdf = gdf[gdf["p_start"].notna() & gdf.geometry.notna() & ~gdf.geometry.is_empty]
    bad_geom = ~gdf.geometry.is_valid     # repair only invalid shapes; "structure" handles mixed-dimension input
    gdf.loc[bad_geom, "geometry"] = gdf.loc[bad_geom].geometry.make_valid(method="structure")
    # Missing or impossible containment dates -> default active window
    bad = gdf["p_end"].isna() | (gdf["p_end"] < gdf["p_start"])
    gdf.loc[bad, "p_end"] = gdf.loc[bad, "p_start"] + pd.Timedelta(days=OPEN_FIRE_DAYS)
    return gdf[["p_name", "p_start", "p_end", "geometry"]].reset_index(drop=True)


def label(df: pd.DataFrame, perims: gpd.GeoDataFrame) -> pd.DataFrame:
    pts = gpd.GeoDataFrame(df[["day"]], geometry=gpd.points_from_xy(df["lon"], df["lat"]), crs=4326)
    j = gpd.sjoin(pts, perims, predicate="within", how="inner")
    ok = (j["day"] >= j["p_start"] - pd.Timedelta(days=PRE_DAYS)) & (
        j["day"] <= j["p_end"] + pd.Timedelta(days=POST_DAYS))
    j = j[ok]
    df = df.copy()
    df["label"] = 0
    df.loc[j.index.unique(), "label"] = 1
    df["fire_name"] = None
    first = j[~j.index.duplicated()]
    df.loc[first.index, "fire_name"] = first["p_name"].values
    return df


# --------------------------------------------------------------------------- #
# 4. Train on 2020, test on 2021
# --------------------------------------------------------------------------- #
FEATURES = [
    "is_viirs", "bright_mir", "bright_tir", "delta_t", "frp", "log_frp",
    "frp_density", "pixel_area_km2", "conf_class", "is_day", "hour_utc", "month",
    "n_same_2km_0d", "n_other_2km_1d", "maxfrp_other_2km_1d", "cross_sensor_confirmed",
    "n_all_5km_0d", "maxfrp_all_5km_0d", "n_all_5km_prev3d", "n_all_1km_prev30_365d",
]


def build(year: int) -> pd.DataFrame:
    cache = ROOT / "data" / f"features_{year}.parquet"
    if cache.exists():
        return pd.read_parquet(cache)
    print(f"[{year}] loading + harmonizing")
    df = load_year(year)
    print(f"[{year}] {len(df):,} detections; computing context features")
    df = add_context_features(df)
    print(f"[{year}] labeling against perimeters")
    df = label(df, load_perimeters(year))
    df.to_parquet(cache)
    return df


def metrics(y, pred, prob) -> dict:
    tn, fp, fn, tp = confusion_matrix(y, pred, labels=[0, 1]).ravel()
    return {
        "n": int(len(y)), "positives": int(y.sum()),
        "accuracy": accuracy_score(y, pred),
        "recall": recall_score(y, pred, zero_division=0),
        "precision": precision_score(y, pred, zero_division=0),
        "f1": f1_score(y, pred, zero_division=0),
        "roc_auc": roc_auc_score(y, prob) if 0 < y.sum() < len(y) else float("nan"),
        "confusion": {"tn": int(tn), "fp": int(fp), "fn": int(fn), "tp": int(tp)},
    }


def fit(train: pd.DataFrame, feats: list[str]) -> RandomForestClassifier:
    rf = RandomForestClassifier(
        n_estimators=300, min_samples_leaf=5, max_features="sqrt",
        class_weight="balanced_subsample", n_jobs=-1, random_state=SEED,
    )
    rf.fit(train[feats].fillna(-1), train["label"])
    return rf


def main() -> None:
    OUT.mkdir(exist_ok=True)
    train, test = build(2020), build(2021)
    for name, d in (("2020 train", train), ("2021 test", test)):
        print(f"{name}: {len(d):,} detections "
              f"(MODIS {int((d.sensor == 'MODIS').sum()):,}, VIIRS {int((d.sensor == 'VIIRS').sum()):,}), "
              f"{d.label.mean():.1%} in mapped wildfires")

    results = {}

    # Main model: combined, harmonized MODIS + VIIRS
    rf = fit(train, FEATURES)
    prob = rf.predict_proba(test[FEATURES].fillna(-1))[:, 1]
    pred = (prob >= 0.5).astype(int)
    results["combined"] = {"all": metrics(test.label.values, pred, prob)}
    for s in ("MODIS", "VIIRS"):
        m = (test.sensor == s).values
        results["combined"][s] = metrics(test.label.values[m], pred[m], prob[m])
    joblib.dump(rf, OUT / "rf_harmonized.joblib")

    # Ablations: what does harmonization buy us?
    single = [f for f in FEATURES if f not in
              ("is_viirs", "n_other_2km_1d", "maxfrp_other_2km_1d", "cross_sensor_confirmed")]
    for s in ("MODIS", "VIIRS"):
        tr, te = train[train.sensor == s], test[test.sensor == s]
        # single-sensor context: recompute cluster/persistence from that sensor only
        tr = add_context_features(tr.drop(columns=[c for c in FEATURES if c.startswith(("n_", "maxfrp_"))]))
        te = add_context_features(te.drop(columns=[c for c in FEATURES if c.startswith(("n_", "maxfrp_"))]))
        m = fit(tr, single)
        p = m.predict_proba(te[single].fillna(-1))[:, 1]
        results[f"{s}_only"] = {s: metrics(te.label.values, (p >= 0.5).astype(int), p)}

    # Naive baseline: trust the sensor's own high/nominal confidence flag
    base = (test.conf_class >= 1).astype(int).values
    results["baseline_confidence_flag"] = {"all": metrics(test.label.values, base, base.astype(float))}

    # Fire-level recall: share of 2021 mapped fires with >=1 detection flagged
    fires = test[test.label == 1].assign(pred=pred[test.label.values == 1])
    per_fire = fires.groupby("fire_name")["pred"].max()
    results["fire_level_recall_2021"] = {
        "fires_with_detections": int(len(per_fire)),
        "fires_caught": int(per_fire.sum()),
        "recall": float(per_fire.mean()) if len(per_fire) else float("nan"),
    }

    imp = pd.Series(rf.feature_importances_, index=FEATURES).sort_values(ascending=False)
    results["feature_importance"] = imp.round(4).to_dict()
    (OUT / "results.json").write_text(json.dumps(results, indent=2, default=float))

    def row(tag, r):
        return (f"{tag:<28} acc {r['accuracy']:.3f}  recall {r['recall']:.3f}  "
                f"precision {r['precision']:.3f}  f1 {r['f1']:.3f}  auc {r['roc_auc']:.3f}  n {r['n']:,}")

    print("\n=== Test on 2021 California (trained on 2020) ===")
    print(row("Combined (harmonized) all", results["combined"]["all"]))
    print(row("  ...on MODIS detections", results["combined"]["MODIS"]))
    print(row("  ...on VIIRS detections", results["combined"]["VIIRS"]))
    print(row("MODIS-only model", results["MODIS_only"]["MODIS"]))
    print(row("VIIRS-only model", results["VIIRS_only"]["VIIRS"]))
    print(row("Baseline: confidence flag", results["baseline_confidence_flag"]["all"]))
    fl = results["fire_level_recall_2021"]
    print(f"Fire-level recall: {fl['fires_caught']}/{fl['fires_with_detections']} = {fl['recall']:.3f}")
    print("Confusion (combined):", results["combined"]["all"]["confusion"])
    print("\nTop features:\n" + imp.head(10).round(3).to_string())


if __name__ == "__main__":
    main()
