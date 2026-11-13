"""Live test: can the shipped model find the fires that are burning right now?

1. Download the last 7 days of NASA FIRMS near-real-time detections for the contiguous US:
   MODIS C6.1 (Terra + Aqua) and NOAA-20 VIIRS 375 m, the same pair the Ember app uses.
   Public files, no key needed.
2. Score every detection with the shipped v3 model (MyApp/ML/ember_rf.bin, cutoff 0.60), exactly as
   the app runs it. The land-cover / burn-history grid only covers California; elsewhere those
   inputs are blank, as in the app outside California.
3. Answer key: NIFC's WFIGS current incidents (interagency, all agencies), each tagged WF
   (wildfire) or RX (prescribed burn), plus the current mapped perimeters. A detection belongs to
   an incident if it is inside its perimeter (+ one pixel), or, without a perimeter, within
   1 km + 2x the radius of a circle of the incident's reported size, from one day before discovery.
   Detections near no reported incident are farm burns, industrial heat, unreported fires or noise:
   not ground truth, but the model should drop most of them.

Run:  uv run --project ml python ml/live_test.py            (re-downloads if files are > 3 h old)
Writes ml/outputs/live/live_test.json and live_fires.csv (one row per current wildfire)
"""

from __future__ import annotations

import io
import json
import time
import urllib.parse
from datetime import datetime, timezone

import geopandas as gpd
import numpy as np
import pandas as pd
from sklearn.neighbors import BallTree

from fetch_data import get
from harmonize import classify, load_static
from small_fires import BUFFER_M
from train_rf import EARTH_KM, OUT, ROOT, load_sensor

LIVE = ROOT / "data" / "raw" / "live"
LIVE_OUT = OUT / "live"
FIRMS = "https://firms.modaps.eosdis.nasa.gov/data/active_fire/{}"
FILES = {"MODIS": "modis-c6.1/csv/MODIS_C6_1_USA_contiguous_and_Hawaii_7d.csv",
         "VIIRS": "noaa-20-viirs-c2/csv/J1_VIIRS_C2_USA_contiguous_and_Hawaii_7d.csv"}
WFIGS = "https://services3.arcgis.com/T4QMspbfLg3qTGWY/arcgis/rest/services/{}/FeatureServer/0/query"
CONUS = (-125.0, 24.0, -66.0, 50.0)
CA_BOX = (-124.5, 32.5, -114.0, 42.1)
MAX_AGE_H = 3


def fresh(path) -> bool:
    return path.exists() and time.time() - path.stat().st_mtime < MAX_AGE_H * 3600


def download() -> None:
    LIVE.mkdir(parents=True, exist_ok=True)
    for s, f in FILES.items():
        p = LIVE / f"{s.lower()}_7d.csv"
        if not fresh(p):
            p.write_bytes(get(FIRMS.format(f)))
    for name in ("WFIGS_Incident_Locations_Current", "WFIGS_Interagency_Perimeters_Current"):
        p = LIVE / f"{name}.geojson"
        if not fresh(p):
            q = dict(where="1=1", outFields="*", outSR=4326, f="geojson")
            p.write_bytes(get(WFIGS.format(name) + "?" + urllib.parse.urlencode(q)))


def load_detections() -> pd.DataFrame:
    parts = []
    for s in FILES:
        path = LIVE / f"{s.lower()}_7d.csv"
        d = load_sensor(path, s)
        d["satellite"] = pd.read_csv(path, usecols=["satellite"])["satellite"].astype(str).values
        parts.append(d)
    df = pd.concat(parts, ignore_index=True)
    w, so, e, n = CONUS
    df = df[df.lat.between(so, n) & df.lon.between(w, e)].sort_values("time").reset_index(drop=True)
    df["delta_t"] = df["bright_mir"] - df["bright_tir"]
    df["pixel_area_km2"] = df["scan"] * df["track"]
    df["frp_density"] = df["frp"] / df["pixel_area_km2"]
    df["log_frp"] = np.log1p(df["frp"].clip(lower=0))
    df["month"] = df["time"].dt.month
    df["hour_utc"] = df["time"].dt.hour + df["time"].dt.minute / 60
    df["day"] = df["time"].dt.floor("D")
    return df


def load_incidents() -> tuple[gpd.GeoDataFrame, gpd.GeoDataFrame]:
    inc = gpd.read_file(LIVE / "WFIGS_Incident_Locations_Current.geojson")
    inc["start"] = pd.to_datetime(inc["FireDiscoveryDateTime"], unit="ms", errors="coerce").dt.floor("D")
    inc["acres"] = pd.to_numeric(inc["IncidentSize"], errors="coerce").fillna(
        pd.to_numeric(inc["DiscoveryAcres"], errors="coerce")).fillna(0.1)
    inc["kind"] = inc["IncidentTypeCategory"]
    inc = inc[inc.kind.isin(["WF", "RX"]) & inc.geometry.notna()].copy()
    inc["inc_id"] = inc["IrwinID"].str.strip("{}").str.lower()
    per = gpd.read_file(LIVE / "WFIGS_Interagency_Perimeters_Current.geojson")
    idcol = next(c for c in per.columns if c.lower() in ("attr_irwinid", "irwinid", "poly_irwinid"))
    per["inc_id"] = per[idcol].astype(str).str.strip("{}").str.lower()
    per = per[per.geometry.notna() & ~per.geometry.is_empty]
    return inc.reset_index(drop=True), per[["inc_id", "geometry"]]


def attach(det: pd.DataFrame, inc: gpd.GeoDataFrame, per: gpd.GeoDataFrame) -> pd.DataFrame:
    """inc_id of the incident each detection belongs to, preferring wildfires and larger incidents."""
    det = det.copy()
    det["inc_id"] = None
    order = inc.assign(w=(inc.kind == "WF").astype(int)).sort_values(["w", "acres"])   # later rows win
    # 1. point + size radius
    xy = np.radians(np.c_[det.lat.values, det.lon.values])
    tree = BallTree(xy, metric="haversine")
    for r in order.itertuples():
        radius_km = 1.0 + 2 * np.sqrt(r.acres * 4046.86 / np.pi) / 1000
        hits = tree.query_radius(np.radians([[r.geometry.y, r.geometry.x]]), r=min(radius_km, 40) / EARTH_KM)[0]
        if pd.notna(r.start):
            hits = hits[det.day.values[hits] >= r.start - pd.Timedelta(days=1)]
        det.iloc[hits, det.columns.get_loc("inc_id")] = r.inc_id
    # 2. mapped perimeters (+ one pixel) override the circle
    p = per.merge(inc[["inc_id", "kind", "acres"]], on="inc_id").sort_values("acres").to_crs(5070)
    pts = gpd.GeoDataFrame(det[["sensor"]], geometry=gpd.points_from_xy(det.lon, det.lat), crs=4326).to_crs(5070)
    for s, b in BUFFER_M.items():
        pb = p.copy(); pb["geometry"] = pb.buffer(b)
        j = gpd.sjoin(pts[pts.sensor == s], pb, predicate="within", how="inner")
        j = j[~j.index.duplicated(keep="last")]
        det.loc[j.index, "inc_id"] = j["inc_id"].values
    kind = inc.set_index("inc_id")["kind"]
    det["truth"] = det["inc_id"].map(kind).fillna("none")
    return det


def main() -> None:
    download()
    now = datetime.now(timezone.utc)
    det = load_detections()
    print(f"FIRMS NRT, contiguous US: {len(det):,} detections "
          f"(MODIS {int((det.sensor == 'MODIS').sum()):,}, NOAA-20 VIIRS {int((det.sensor == 'VIIRS').sum()):,}), "
          f"{det.time.min():%Y-%m-%d %H:%M} to {det.time.max():%Y-%m-%d %H:%M} UTC")
    det = classify(det, load_static()).assign(satellite=det["satellite"].values)
    inc, per = load_incidents()
    det = attach(det, inc, per)
    w, so, e, n = CA_BOX
    det["in_ca_box"] = det.lat.between(so, n) & det.lon.between(w, e)
    latest = det.time.max()
    det["last_24h"] = det.time >= latest - pd.Timedelta(hours=24)

    def share(m):
        return {"detections": int(m.sum()), "kept_by_model": float(det.loc[m, "is_wildfire"].mean()) if m.any() else None}

    res = {"run_utc": now.strftime("%Y-%m-%d %H:%M"), "data_from_utc": f"{det.time.min():%Y-%m-%d %H:%M}",
           "data_to_utc": f"{latest:%Y-%m-%d %H:%M}", "cutoff": 0.60,
           "incidents": {"wildfires": int((inc.kind == "WF").sum()), "prescribed": int((inc.kind == "RX").sum()),
                         "mapped_perimeters": int(len(per))},
           "detections": {k: share(det.truth == k) for k in ("WF", "RX", "none")}}
    res["detections_california"] = {k: share((det.truth == k) & det.in_ca_box) for k in ("WF", "RX", "none")}

    # Fire level: each current wildfire / prescribed burn that FIRMS saw at least once
    g = det[det.truth != "none"].groupby("inc_id").agg(
        detections=("is_wildfire", "size"), kept=("is_wildfire", "sum"), max_prob=("wildfire_prob", "max"),
        median_prob=("wildfire_prob", "median"), last_seen=("time", "max"), last24=("last_24h", "sum"),
        sensors=("sensor", lambda s: "+".join(sorted(set(s)))))
    g = g.join(inc.set_index("inc_id")[["IncidentName", "kind", "acres", "POOState", "start", "PercentContained"]])
    g["caught"] = g.kept > 0
    fires = {}
    for k in ("WF", "RX"):
        x = g[g.kind == k]
        by = {}
        for lo, hi, lab in ((0, 10, "<10 acres"), (10, 100, "10-100"), (100, 1000, "100-1,000"), (1000, 1e9, "1,000+")):
            y = x[(x.acres >= lo) & (x.acres < hi)]
            by[lab] = f"{int(y.caught.sum())}/{len(y)}"
        fires[k] = {"seen_by_firms": len(x), "kept_by_model": int(x.caught.sum()), "by_size": by,
                    "reported_total": int((inc.kind == k).sum())}
    res["fires"] = fires

    now_burning = g[(g.kind == "WF") & (g.last24 > 0)].sort_values("acres", ascending=False)
    res["wildfires_detected_last_24h"] = [
        {"name": str(r.IncidentName).title(), "state": str(r.POOState).replace("US-", ""), "acres": round(float(r.acres)),
         "contained_pct": None if pd.isna(r.PercentContained) else float(r.PercentContained),
         "detections_7d": int(r.detections), "kept": int(r.kept), "max_prob": round(float(r.max_prob), 2),
         "caught": bool(r.caught), "last_seen_utc": f"{r.last_seen:%Y-%m-%d %H:%M}"}
        for _, r in now_burning.iterrows()]
    missed = g[(g.kind == "WF") & ~g.caught].sort_values("acres", ascending=False)
    res["wildfires_missed"] = [{"name": str(r.IncidentName).title(), "state": str(r.POOState).replace("US-", ""),
                                "acres": round(float(r.acres)), "detections_7d": int(r.detections),
                                "max_prob": round(float(r.max_prob), 2)} for _, r in missed.iterrows()]

    LIVE_OUT.mkdir(parents=True, exist_ok=True)
    (LIVE_OUT / "live_test.json").write_text(json.dumps(res, indent=2, default=str))
    g[g.kind == "WF"].sort_values("acres", ascending=False).to_csv(LIVE_OUT / "live_fires.csv")
    print(json.dumps({k: v for k, v in res.items() if k not in ("wildfires_detected_last_24h", "wildfires_missed")}, indent=1))
    print("\nWildfires FIRMS saw in the last 24 h:")
    for f in res["wildfires_detected_last_24h"]:
        print(f"  {'CAUGHT' if f['caught'] else 'missed'}  {f['name']:<24} {f['state']:<3} {f['acres']:>8,} ac  "
              f"{f['kept']}/{f['detections_7d']} kept  max p {f['max_prob']}  last {f['last_seen_utc']}")
    print("\nWildfires seen by FIRMS but dropped entirely:", [(f["name"], f["state"], f["acres"]) for f in res["wildfires_missed"][:15]])


if __name__ == "__main__":
    main()
