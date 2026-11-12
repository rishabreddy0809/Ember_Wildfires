"""Experiments to raise recall on small fires (few detections), using the app feature set.

Compares: perimeter-buffered labels (pixel-size tolerance), per-fire sample weighting,
and decision threshold. Reports detection-level metrics and fire-level recall by size.

Run:  uv run --project ml python ml/small_fires.py
"""
import numpy as np
import pandas as pd
import geopandas as gpd
from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import roc_auc_score

from export_app_model import APP_FEATURES
from train_rf import POST_DAYS, PRE_DAYS, build, load_perimeters

BUFFER_M = {"MODIS": 1000, "VIIRS": 375}   # ~ one nadir pixel
BUCKETS = [(1, 4), (5, 19), (20, 99), (100, 10**9)]


def label_buffered(df: pd.DataFrame, year: int) -> pd.DataFrame:
    """Label 1 if within one pixel of a perimeter during its active dates. Also records the fire."""
    perims = load_perimeters(year).to_crs(3310)
    pts = gpd.GeoDataFrame(df[["day", "sensor"]], geometry=gpd.points_from_xy(df.lon, df.lat), crs=4326).to_crs(3310)
    hits = []
    for s, b in BUFFER_M.items():
        p = perims.copy(); p["geometry"] = p.buffer(b)
        j = gpd.sjoin(pts[pts.sensor == s], p, predicate="within", how="inner")
        hits.append(j[(j.day >= j.p_start - pd.Timedelta(days=PRE_DAYS)) & (j.day <= j.p_end + pd.Timedelta(days=POST_DAYS))])
    j = pd.concat(hits)
    j = j[~j.index.duplicated()]
    out = df.copy()
    out["label"] = 0; out.loc[j.index, "label"] = 1
    out["fire_name"] = None; out.loc[j.index, "fire_name"] = j.p_name.values
    return out


def fire_weights(df: pd.DataFrame, power: float) -> np.ndarray:
    """Positives weighted by (detections in their fire)^-power, rescaled to keep total positive weight."""
    w = np.ones(len(df))
    pos = df.label.values == 1
    if power > 0:
        n = df[pos].groupby("fire_name")["label"].transform("size").values
        wp = n.astype(float) ** -power
        w[pos] = wp * pos.sum() / wp.sum()
    return w


def evaluate(test, prob, thr):
    y, pr = test.label.values, prob >= thr
    tp, fp = (pr & (y == 1)).sum(), (pr & (y == 0)).sum()
    tn, fn = (~pr & (y == 0)).sum(), (~pr & (y == 1)).sum()
    f = test[y == 1].assign(p=pr[y == 1]).groupby("fire_name")["p"].agg(["size", "max"])
    buckets = [f"{int(f[(f['size'] >= lo) & (f['size'] <= hi)]['max'].sum())}/{int(((f['size'] >= lo) & (f['size'] <= hi)).sum())}" for lo, hi in BUCKETS]
    return dict(recall=tp / (tp + fn), precision=tp / (tp + fp), nonfire_removed=tn / (tn + fp),
                fires=f"{int(f['max'].sum())}/{len(f)}", by_size="  ".join(buckets))


def main():
    base_tr, base_te = build(2020), build(2021)
    buf_tr, buf_te = label_buffered(base_tr, 2020), label_buffered(base_te, 2021)
    print(f"buffered labels: 2020 positives {base_tr.label.mean():.1%} -> {buf_tr.label.mean():.1%}; "
          f"2021 fires with detections {base_te[base_te.label == 1].fire_name.nunique()} -> {buf_te[buf_te.label == 1].fire_name.nunique()}")
    print("fire recall by size = fires with 1-4 / 5-19 / 20-99 / 100+ detections\n")

    rows = []
    for lab_name, tr, te in (("exact perimeter", base_tr, base_te), ("buffered 1 pixel", buf_tr, buf_te)):
        for power in (0.0, 0.5, 1.0):
            rf = RandomForestClassifier(n_estimators=100, max_depth=14, min_samples_leaf=20, max_features="sqrt",
                                        class_weight="balanced_subsample", n_jobs=-1, random_state=42)
            rf.fit(tr[APP_FEATURES].fillna(-1), tr.label, sample_weight=fire_weights(tr, power))
            prob = rf.predict_proba(te[APP_FEATURES].fillna(-1))[:, 1]
            auc = roc_auc_score(te.label, prob)
            for thr in (0.5, 0.35, 0.2):
                r = evaluate(te, prob, thr)
                rows.append(dict(labels=lab_name, fire_weight=power, threshold=thr, auc=auc, **r))
                print(f"{lab_name:17} w^-{power:<3} thr {thr:<4} auc {auc:.3f}  recall {r['recall']:.3f}  "
                      f"precision {r['precision']:.3f}  non-wildfire removed {r['nonfire_removed']:.3f}  "
                      f"fires {r['fires']:>7}  by size {r['by_size']}")
    pd.DataFrame(rows).to_csv("ml/outputs/small_fire_experiments.csv", index=False)


if __name__ == "__main__":
    main()
