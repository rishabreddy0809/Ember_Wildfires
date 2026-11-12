"""v3: the best model, and the one the Ember app ships.

Changes from v2:
- Causal context: features look only at the same UTC day and the day before, never ahead,
  so the live app scores today's detections the same way the model was trained.
- Day/night persistence: wildfires burn through the night and into the next day;
  farm burns are short daytime fires.
- Cluster power: total FRP within 5 km on the same day.
- Static context (build_static_grids.py): NLCD 2019 land cover fractions and the number of
  months in 2017-2019 with fire detections nearby (repeat farm burns, refineries, plants).
- Hyperparameters, fire weighting and the decision threshold are chosen by cross-validation
  on 2020 only, grouped by month. 2021 is used once, for the final test.
- 10 % of training rows have the static features blanked, so the model still works
  outside the grids (the app falls back to -1 there).
- Sensor-loss training (found by stress_test.py): the 2020 training set also includes a
  VIIRS-only and a MODIS-only copy with context recomputed from that sensor alone, and
  `other_sensor_present` says whether the other sensor reported anything that UTC day.
  Without this, recall fell from 96 % to 75 % when only VIIRS was available.

Run:  uv run --project ml python ml/train_v3.py
"""

from __future__ import annotations

import itertools
import json

import numpy as np
import pandas as pd
from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import roc_auc_score
from sklearn.model_selection import GroupKFold
from sklearn.neighbors import BallTree

from build_static_grids import BANDS, load_grids, lookup
from export_app_model import APP_FEATURES as V2_FEATURES
from export_app_model import predict_like_swift, write_forest
from small_fires import fire_weights, label_buffered
from train_rf import EARTH_KM, OUT, ROOT, build

BIN = ROOT.parent / "MyApp" / "ML" / "ember_rf.bin"
SEED = 42
RADIOMETRIC = ["is_viirs", "bright_mir", "bright_tir", "delta_t", "frp", "log_frp", "frp_density",
               "pixel_area_km2", "conf_class", "is_day", "hour_utc", "month"]
CONTEXT = ["n_same_2km_0d", "n_other_2km_prev1d", "maxfrp_other_2km_prev1d", "cross_sensor_confirmed",
           "n_all_5km_0d", "maxfrp_all_5km_0d", "sumfrp_all_5km_0d", "n_all_5km_prevday",
           "n_night_5km_prev1d", "n_day_5km_prev1d", "other_sensor_present"]
FEATURES = RADIOMETRIC + CONTEXT + BANDS
BUCKETS = [(1, 4), (5, 19), (20, 99), (100, 10**9)]


# --------------------------------------------------------------------------- #
# Features
# --------------------------------------------------------------------------- #
def neighbors(src: pd.DataFrame, ref: pd.DataFrame, radius_km: float, day_lo: int, day_hi: int):
    """For each src row: count, max FRP, and sum FRP of ref rows within radius_km (haversine,
    inclusive) whose UTC day is in [day + day_lo, day + day_hi]. Includes the row itself if
    it is in ref; callers subtract it where needed."""
    n = np.zeros(len(src), np.int32); mx = np.zeros(len(src)); sm = np.zeros(len(src))
    if ref.empty or src.empty:
        return n, mx, sm
    rd, sd = ref["day"].values, src["day"].values
    rfrp = ref["frp"].fillna(0).values
    for d in np.unique(sd):
        r = (rd >= d + np.timedelta64(day_lo, "D")) & (rd <= d + np.timedelta64(day_hi, "D"))
        if not r.any():
            continue
        idx = np.flatnonzero(sd == d)
        tree = BallTree(np.radians(ref.loc[r, ["lat", "lon"]].values), metric="haversine")
        hits = tree.query_radius(np.radians(src.iloc[idx][["lat", "lon"]].values), r=radius_km / EARTH_KM)
        f = rfrp[r]
        for k, h in zip(idx, hits):
            n[k] = len(h)
            if len(h):
                mx[k] = f[h].max(); sm[k] = f[h].sum()
    return n, mx, sm


def context_features(df: pd.DataFrame) -> pd.DataFrame:
    df = df.reset_index(drop=True).copy()
    is_v = df["is_viirs"].values == 1
    night = df["is_day"].values == 0
    for flag in (False, True):
        m = is_v == flag
        src, same, other = df[m], df[m], df[~m]
        df.loc[m, "n_same_2km_0d"] = neighbors(src, same, 2, 0, 0)[0] - 1
        c, mx, _ = neighbors(src, other, 2, -1, 0)
        df.loc[m, "n_other_2km_prev1d"] = c
        df.loc[m, "maxfrp_other_2km_prev1d"] = mx
    df["cross_sensor_confirmed"] = (df["n_other_2km_prev1d"] > 0).astype(int)
    c, mx, sm = neighbors(df, df, 5, 0, 0)
    df["n_all_5km_0d"], df["maxfrp_all_5km_0d"], df["sumfrp_all_5km_0d"] = c - 1, mx, sm
    df["n_all_5km_prevday"] = neighbors(df, df, 5, -1, -1)[0]
    df["n_night_5km_prev1d"] = neighbors(df, df[night], 5, -1, 0)[0] - night
    df["n_day_5km_prev1d"] = neighbors(df, df[~night], 5, -1, 0)[0] - (~night)
    viirs_days, modis_days = set(df.loc[is_v, "day"]), set(df.loc[~is_v, "day"])
    df["other_sensor_present"] = [int(d in (modis_days if v else viirs_days)) for d, v in zip(df["day"], is_v)]
    return df


BASE_COLS = ["lat", "lon", "time", "day", "sensor", "label", "fire_name"] + RADIOMETRIC + ["scan", "track"]


def build_v3(year: int, grids, only: str | None = None) -> pd.DataFrame:
    """Features for a year. only="VIIRS"/"MODIS" recomputes context as if the other sensor were gone."""
    cache = ROOT / "data" / f"features_v3_{year}{'_' + only if only else ''}.parquet"
    if cache.exists():
        return pd.read_parquet(cache)
    base = label_buffered(build(year), year)[BASE_COLS]
    if only:
        base = base[base.sensor == only]
    df = context_features(base)
    df = pd.concat([df, lookup(grids, df.lat.values, df.lon.values)], axis=1)
    df.to_parquet(cache)
    return df


def build_training(year: int, grids) -> pd.DataFrame:
    """Both sensors together, plus a single-sensor copy for each sensor (half weight via `copy_w`)."""
    parts = [build_v3(year, grids).assign(copy_w=1.0)]
    parts += [build_v3(year, grids, only=s).assign(copy_w=0.5) for s in ("VIIRS", "MODIS")]
    return pd.concat(parts, ignore_index=True)


def weights(df: pd.DataFrame, power: float) -> np.ndarray:
    return fire_weights(df, power) * df["copy_w"].values


# --------------------------------------------------------------------------- #
# Model selection on 2020 only
# --------------------------------------------------------------------------- #
def X(df: pd.DataFrame, feats=FEATURES) -> np.ndarray:
    return df[feats].astype(float).fillna(-1).values


def blank_static(df: pd.DataFrame, frac: float, seed: int) -> pd.DataFrame:
    df = df.copy()
    m = np.random.default_rng(seed).random(len(df)) < frac
    df.loc[m, BANDS] = np.nan
    return df


def fire_report(df: pd.DataFrame, pred: np.ndarray) -> dict:
    y = df.label.values
    tp, fp = int((pred & (y == 1)).sum()), int((pred & (y == 0)).sum())
    tn, fn = int((~pred & (y == 0)).sum()), int((~pred & (y == 1)).sum())
    f = df[y == 1].assign(p=pred[y == 1]).groupby("fire_name")["p"].agg(["size", "max"])
    by = {f"{lo}-{hi if hi < 10**9 else '+'}": f"{int(f[(f['size'] >= lo) & (f['size'] <= hi)]['max'].sum())}/"
          f"{int(((f['size'] >= lo) & (f['size'] <= hi)).sum())}" for lo, hi in BUCKETS}
    return dict(accuracy=(tp + tn) / len(y), recall=tp / (tp + fn), precision=tp / max(tp + fp, 1),
                nonfire_removed=tn / (tn + fp), fires_caught=int(f["max"].sum()), fires=len(f),
                fire_recall=float(f["max"].mean()), by_size=by, confusion=dict(tn=tn, fp=fp, fn=fn, tp=tp))


def make_rf(depth, leaf, maxf, trees=100):
    return RandomForestClassifier(n_estimators=trees, max_depth=depth, min_samples_leaf=leaf, max_features=maxf,
                                  class_weight="balanced_subsample", n_jobs=-1, random_state=SEED)


def select(train: pd.DataFrame) -> dict:
    """Grouped-by-month 4-fold CV on 2020. Score = mean(fire-level recall, non-wildfire removed),
    requiring detection-level recall >= 0.97 so real fire pixels aren't thrown away."""
    groups = train.time.dt.month.values
    folds = list(GroupKFold(4).split(train, groups=groups))
    best, log = None, []
    for depth, leaf, maxf, power in itertools.product((14, 20), (10, 30), ("sqrt", 0.4), (0.5, 1.0)):
        oof = np.zeros(len(train))
        for a, b in folds:
            tr = blank_static(train.iloc[a], 0.10, SEED)
            m = make_rf(depth, leaf, maxf, trees=60).fit(X(tr), tr.label, sample_weight=weights(tr, power))
            oof[b] = m.predict_proba(X(train.iloc[b]))[:, 1]
        for thr in (0.3, 0.4, 0.5, 0.6):
            r = fire_report(train, oof >= thr)
            score = (r["fire_recall"] + r["nonfire_removed"]) / 2 if r["recall"] >= 0.97 else 0
            log.append(dict(depth=depth, leaf=leaf, max_features=maxf, power=power, thr=thr, score=score,
                            fire_recall=r["fire_recall"], removed=r["nonfire_removed"], recall=r["recall"]))
            if best is None or score > best["score"]:
                best = log[-1]
        print(f"  cv depth {depth} leaf {leaf} maxf {maxf} w^-{power}: best so far {best['score']:.3f}")
    pd.DataFrame(log).to_csv(OUT / "v3_cv_2020.csv", index=False)
    return best


# --------------------------------------------------------------------------- #
def main() -> None:
    grids = load_grids()
    train, test = build_training(2020, grids), build_v3(2021, grids)
    print(f"2020: {len(train):,} detections, {train.label.mean():.1%} wildfire | "
          f"2021: {len(test):,}, {test.label.mean():.1%} wildfire")

    print("model selection on 2020 (grouped by month):")
    best = select(train)
    print("chosen:", best)
    depth, leaf, maxf, power, thr = best["depth"], best["leaf"], best["max_features"], best["power"], best["thr"]
    maxf = maxf if maxf == "sqrt" else float(maxf)

    tr = blank_static(train, 0.10, SEED)
    rf = make_rf(depth, leaf, maxf).fit(X(tr), tr.label, sample_weight=weights(tr, power))
    prob = rf.predict_proba(X(test))[:, 1]

    results = {"chosen": {**best, "trees": 100}, "features": FEATURES}
    results["v3"] = {**fire_report(test, prob >= thr), "auc": roc_auc_score(test.label, prob)}
    p_nostatic = rf.predict_proba(X(test.assign(**{b: np.nan for b in BANDS})))[:, 1]
    results["v3_without_static_grids"] = {**fire_report(test, p_nostatic >= thr), "auc": roc_auc_score(test.label, p_nostatic)}
    for s in ("MODIS", "VIIRS"):
        m = (test.sensor == s).values
        results[f"v3_{s}"] = fire_report(test[m], prob[m] >= thr)
        solo = build_v3(2021, grids, only=s)
        ps = rf.predict_proba(X(solo))[:, 1]
        results[f"v3_{s}_only_input"] = {**fire_report(solo, ps >= thr), "auc": roc_auc_score(solo.label, ps)}

    # v2 (previous app model) on the same labels, for comparison
    tr2, te2 = label_buffered(build(2020), 2020), label_buffered(build(2021), 2021)
    v2 = make_rf(14, 20, "sqrt").fit(X(tr2, V2_FEATURES), tr2.label, sample_weight=fire_weights(tr2, 1.0))
    p2 = v2.predict_proba(X(te2, V2_FEATURES))[:, 1]
    results["v2"] = {**fire_report(te2, p2 >= 0.5), "auc": roc_auc_score(te2.label, p2)}
    results["baseline_all_fire"] = fire_report(test, np.ones(len(test), bool))
    results["baseline_confidence"] = fire_report(test, (test.conf_class >= 1).values)

    imp = pd.Series(rf.feature_importances_, index=FEATURES).sort_values(ascending=False)
    results["feature_importance"] = imp.round(4).to_dict()
    (OUT / "v3_results.json").write_text(json.dumps(results, indent=2, default=float))

    write_forest(rf, BIN)
    check = predict_like_swift(BIN, X(test)[:20000])
    nodes = sum(e.tree_.node_count for e in rf.estimators_)
    print(f"exported {BIN.name}: {nodes:,} nodes, {BIN.stat().st_size / 1e6:.1f} MB, "
          f"max |sklearn - exported| {np.abs(check - prob[:20000]).max():.1e}")

    # Golden file for the Swift parity test: a 4-day window, features recomputed on that window alone
    win = test[(test.day >= "2021-08-14") & (test.day <= "2021-08-17")]
    win = context_features(win[BASE_COLS])
    win = pd.concat([win, lookup(grids, win.lat.values, win.lon.values)], axis=1)
    win["prob"] = rf.predict_proba(X(win))[:, 1]
    win["time"] = win["time"].dt.strftime("%Y-%m-%d %H%M")
    win[["lat", "lon", "time", "sensor", "bright_mir", "bright_tir", "frp", "scan", "track", "is_day",
         "conf_class", *CONTEXT, *BANDS, "prob"]].to_csv(OUT / "swift_golden.csv", index=False)
    (OUT / "swift_threshold.txt").write_text(str(thr))

    def row(name, r):
        return (f"{name:<26} acc {r['accuracy']:.3f}  recall {r['recall']:.3f}  precision {r['precision']:.3f}  "
                f"non-wildfire removed {r['nonfire_removed']:.3f}  fires {r['fires_caught']}/{r['fires']}  {r['by_size']}")
    print("\n=== 2021 test (trained on 2020; labels = perimeters + 1 pixel) ===")
    print(row("v3 (new app model)", results["v3"]), f" auc {results['v3']['auc']:.3f}")
    print(row("v3 outside grids", results["v3_without_static_grids"]), f" auc {results['v3_without_static_grids']['auc']:.3f}")
    print(row("  v3 on MODIS", results["v3_MODIS"]))
    print(row("  v3 on VIIRS", results["v3_VIIRS"]))
    print(row("  v3, VIIRS only (no MODIS)", results["v3_VIIRS_only_input"]), f" auc {results['v3_VIIRS_only_input']['auc']:.3f}")
    print(row("  v3, MODIS only (no VIIRS)", results["v3_MODIS_only_input"]), f" auc {results['v3_MODIS_only_input']['auc']:.3f}")
    print(row("v2 (previous app model)", results["v2"]), f" auc {results['v2']['auc']:.3f}")
    print(row("always 'wildfire'", results["baseline_all_fire"]))
    print(row("FIRMS confidence flag", results["baseline_confidence"]))
    print("\nTop features:\n" + imp.head(12).round(3).to_string())


if __name__ == "__main__":
    main()
