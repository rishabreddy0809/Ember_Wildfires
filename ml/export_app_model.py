"""Train the compact random forest the Ember app ships, and export it for Swift.

The app downloads only 1-10 days at a time, so this model uses only features it can
compute from that window (no 3-day or 1-year history). Measured on 2021 this costs
almost nothing compared with the full model (see README).

Writes:
  MyApp/ML/ember_rf.bin            the forest, in the binary format EmberForest.swift reads
  ml/outputs/app_model_results.json
  ml/outputs/swift_golden.csv      raw detections + Python probabilities, used to check
                                   that the Swift features + inference match Python exactly

Run:  uv run --project ml python ml/export_app_model.py
"""

from __future__ import annotations

import json
import struct
from pathlib import Path

import numpy as np
import pandas as pd
from sklearn.ensemble import RandomForestClassifier

from train_rf import FEATURES, OUT, ROOT, add_context_features, build, metrics

# v2 (small-fire fix, see ml/small_fires.py): labels allow one pixel of tolerance around
# each perimeter, and each wildfire detection is weighted by 1 / (detections in its fire)
# so small fires count as much as big ones. Both settings were chosen with 2020-only
# cross-validation grouped by month; 2021 was not used to pick them.
FIRE_WEIGHT_POWER = 1.0

APP_FEATURES = [f for f in FEATURES if f not in ("n_all_1km_prev30_365d", "n_all_5km_prev3d")]
BIN = ROOT.parent / "MyApp" / "ML" / "ember_rf.bin"
MAGIC, FORMAT_VERSION = b"EMRF", 1


def write_forest(rf: RandomForestClassifier, path: Path) -> None:
    """Little-endian layout:
    header: 'EMRF', u32 version, u32 n_trees, u32 n_features
    per tree: u32 n_nodes, then 5 arrays of n_nodes each:
      i16 feature (-1 = leaf), f64 threshold, i32 left, i32 right, f32 P(wildfire) at node
    Rule (same as sklearn): go left if x[feature] <= threshold.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "wb") as f:
        f.write(MAGIC + struct.pack("<III", FORMAT_VERSION, len(rf.estimators_), rf.n_features_in_))
        for est in rf.estimators_:
            t = est.tree_
            v = t.value[:, 0, :]
            prob = (v[:, 1] / v.sum(axis=1)).astype("<f4")
            feat = np.where(t.children_left == -1, -1, t.feature).astype("<i2")
            f.write(struct.pack("<I", t.node_count))
            f.write(feat.tobytes())
            f.write(t.threshold.astype("<f8").tobytes())
            f.write(t.children_left.astype("<i4").tobytes())
            f.write(t.children_right.astype("<i4").tobytes())
            f.write(prob.tobytes())


def predict_like_swift(path: Path, X: np.ndarray) -> np.ndarray:
    """Re-reads the exported file and runs it the way Swift does (float32 features, float64 thresholds)."""
    data = path.read_bytes()
    _, n_trees, _ = struct.unpack_from("<III", data, 4)
    off, trees = 16, []
    for _ in range(n_trees):
        (n,) = struct.unpack_from("<I", data, off); off += 4
        arrs = []
        for dt, size in (("<i2", 2), ("<f8", 8), ("<i4", 4), ("<i4", 4), ("<f4", 4)):
            arrs.append(np.frombuffer(data, dt, n, off)); off += n * size
        trees.append(arrs)
    X = X.astype(np.float32)
    out = np.zeros(len(X))
    for feat, thr, left, right, prob in trees:
        node = np.zeros(len(X), dtype=np.int64)
        while True:
            internal = feat[node] >= 0
            if not internal.any():
                break
            i = np.flatnonzero(internal)
            go_left = X[i, feat[node[i]]] <= thr[node[i]]
            node[i] = np.where(go_left, left[node[i]], right[node[i]])
        out += prob[node]
    return out / n_trees


def main() -> None:
    from small_fires import fire_weights, label_buffered

    train, test = label_buffered(build(2020), 2020), label_buffered(build(2021), 2021)
    rf = RandomForestClassifier(
        n_estimators=100, max_depth=14, min_samples_leaf=20, max_features="sqrt",
        class_weight="balanced_subsample", n_jobs=-1, random_state=42,
    ).fit(train[APP_FEATURES].fillna(-1), train["label"],
          sample_weight=fire_weights(train, FIRE_WEIGHT_POWER))

    prob = rf.predict_proba(test[APP_FEATURES].fillna(-1))[:, 1]
    res = {"features": APP_FEATURES, "labels": "perimeters + 1 pixel", "fire_weight_power": FIRE_WEIGHT_POWER,
           "test_2021": metrics(test.label.values, (prob >= 0.5).astype(int), prob)}
    f = test[test.label == 1].assign(p=prob[test.label.values == 1] >= 0.5).groupby("fire_name")["p"].agg(["size", "max"])
    res["fire_level_2021"] = {f"{lo}-{hi}": f"{int(f[(f['size'] >= lo) & (f['size'] <= hi)]['max'].sum())}/{int(((f['size'] >= lo) & (f['size'] <= hi)).sum())}"
                              for lo, hi in ((1, 4), (5, 19), (20, 99), (100, 10**9))}
    res["fire_level_2021"]["all"] = f"{int(f['max'].sum())}/{len(f)}"
    for s in ("MODIS", "VIIRS"):
        m = (test.sensor == s).values
        res[s] = metrics(test.label.values[m], (prob[m] >= 0.5).astype(int), prob[m])
    (OUT / "app_model_results.json").write_text(json.dumps(res, indent=2, default=float))

    write_forest(rf, BIN)
    swift_like = predict_like_swift(BIN, test[APP_FEATURES].fillna(-1).values[:20000])
    print(f"export check: max |sklearn - exported| = {np.abs(swift_like - prob[:20000]).max():.2e}")

    # Golden file: a 3-day window, features recomputed on that window alone (as the app does)
    win = test[(test.day >= "2021-08-15") & (test.day <= "2021-08-17")]
    raw_cols = ["lat", "lon", "time", "sensor", "is_viirs", "bright_mir", "bright_tir", "frp",
                "scan", "track", "is_day", "conf_class", "delta_t", "pixel_area_km2",
                "frp_density", "log_frp", "month", "hour_utc", "day"]
    win = add_context_features(win[raw_cols].reset_index(drop=True))
    win["prob"] = rf.predict_proba(win[APP_FEATURES].fillna(-1))[:, 1]
    win["time"] = win["time"].dt.strftime("%Y-%m-%d %H%M")
    win[["lat", "lon", "time", "sensor", "bright_mir", "bright_tir", "frp", "scan", "track",
         "is_day", "conf_class", *APP_FEATURES[12:], "prob"]].to_csv(OUT / "swift_golden.csv", index=False)

    t = res["test_2021"]
    print(f"app model on 2021: acc {t['accuracy']:.3f} recall {t['recall']:.3f} "
          f"precision {t['precision']:.3f} auc {t['roc_auc']:.3f}  fires by size {res['fire_level_2021']}")
    print(f"wrote {BIN} ({BIN.stat().st_size / 1e6:.1f} MB), golden rows: {len(win):,}")


if __name__ == "__main__":
    main()
