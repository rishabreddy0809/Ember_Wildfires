"""v4: the year-round model.

Why: v3 (trained on California 2020) learned the calendar. It keeps 93-99 % of mapped-fire detections
from June to October, but almost none outside it: 0 % of the January 2025 LA fires (Palisades, Eaton),
1 % in November 2025, and 1 of 12 wildfires burning in the US in the live test of 6-13 Nov 2026.
With `month` forced to August the same live detections pass, prescribed burns included, so the month
input was doing the work.

Changes from v3 (features, labels and the exported format are the same):
- Training data: California 2020, 2021, 2022 and 2023, every month (v3: 2020 only).
- `month` is held at a constant while training, so no tree can split on it. It stays in the
  29-value feature vector, so the app's Swift code is unchanged; whatever month it passes is ignored.
- Month-balanced weights: within each calendar month, wildfire and non-wildfire detections are
  scaled toward the same total weight (strength `mb`, chosen by CV), on top of v3's per-fire weighting,
  so winter fires are not drowned out by winter farm burns.
- Selection: leave-one-year-out CV over 2020-2023. Score = mean of the in-season (Jun-Oct) and
  off-season (Nov-May) scores, each = mean(fire-level recall, non-wildfire removed), requiring
  detection-level recall >= 0.95 in season.
- 2024 and 2025 are never used for training or selection: they are the test years (and the years of
  the harmonized record).

Run:  uv run --project ml python ml/fetch_data.py 2020 2021 2022 2023
      uv run --project ml python ml/train_v4.py
Writes MyApp/ML/ember_rf.bin (+ outputs/swift_threshold.txt, swift_golden.csv, v4_results.json).
"""

from __future__ import annotations

import json
import sys

import numpy as np
import pandas as pd
from sklearn.metrics import roc_auc_score

from build_static_grids import BANDS, lookup
from export_app_model import predict_like_swift, write_forest
from harmonize import load_static
from small_fires import fire_weights, label_buffered
from train_rf import OUT, ROOT, load_year
from train_v3 import BASE_COLS, BIN, CONTEXT, FEATURES, X, blank_static, context_features, fire_report, make_rf

TRAIN_YEARS = [2020, 2021, 2022, 2023]
TEST_YEARS = [2024, 2025]
IN_SEASON = [6, 7, 8, 9, 10]
SEED = 42
V3_BIN = ROOT / "data" / "ember_rf_v3.bin"          # copy of the old model, for comparison
MB_GRID = [0.0, 0.5, 1.0]
THR_GRID = [0.3, 0.4, 0.5, 0.6]


# --------------------------------------------------------------------------- #
def build(year: int, grids, only: str | None = None) -> pd.DataFrame:
    cache = ROOT / "data" / f"features_v4_{year}{'_' + only if only else ''}.parquet"
    if cache.exists():
        return pd.read_parquet(cache)
    base = label_buffered(load_year(year), year)
    base["fire_name"] = base["fire_name"].map(lambda n: f"{year}:{n}" if n is not None else None)
    base = base[BASE_COLS]
    if only:
        base = base[base.sensor == only]
    df = context_features(base)
    df = pd.concat([df, lookup(grids, df.lat.values, df.lon.values)], axis=1)
    df["year"] = year
    df.to_parquet(cache)
    return df


def training_set(years, grids) -> pd.DataFrame:
    parts = []
    for y in years:
        parts.append(build(y, grids).assign(copy_w=1.0))
        parts += [build(y, grids, only=s).assign(copy_w=0.5) for s in ("VIIRS", "MODIS")]
    return pd.concat(parts, ignore_index=True)


def Xn(df: pd.DataFrame) -> np.ndarray:
    """Feature matrix with `month` neutralized (constant), so it can never be split on."""
    return X(df.assign(month=0))


def weights(df: pd.DataFrame, mb: float) -> np.ndarray:
    """v3 weights (1 / fire size, half weight for single-sensor copies) times month balancing:
    each (month, label) group is scaled by (target / group total) ** mb, target = mean group total."""
    w = fire_weights(df, 1.0) * df["copy_w"].values
    if mb > 0:
        key = df["time"].dt.month.values * 2 + df["label"].values
        tot = pd.Series(w).groupby(key).transform("sum").values
        target = pd.Series(w).groupby(key).sum().mean()
        w = w * (target / tot) ** mb
        w *= len(w) / w.sum()
    return w


def season_report(df: pd.DataFrame, pred: np.ndarray) -> dict:
    ins = df.time.dt.month.isin(IN_SEASON).values
    out = {"all": fire_report(df, pred)}
    for name, m in (("in_season", ins), ("off_season", ~ins)):
        d = df[m]
        out[name] = fire_report(d, pred[m]) if d.label.sum() else None
    return out


def season_score(r: dict) -> float:
    def s(x):
        return (x["fire_recall"] + x["nonfire_removed"]) / 2 if x else 0.0
    if r["in_season"] is None or r["in_season"]["recall"] < 0.95:
        return 0.0
    return (s(r["in_season"]) + s(r["off_season"])) / 2


def select(train: pd.DataFrame) -> tuple[dict, list]:
    log = []
    for mb in MB_GRID:
        oof = np.full(len(train), np.nan)
        for y in TRAIN_YEARS:
            te = (train.year == y).values & (train.copy_w == 1.0).values
            tr = blank_static(train[train.year != y], 0.10, SEED)
            m = make_rf(14, 30, 0.4, trees=40).fit(Xn(tr), tr.label, sample_weight=weights(tr, mb))
            oof[te] = m.predict_proba(Xn(train[te]))[:, 1]
            print(f"  cv mb {mb}: held out {y}", flush=True)
        ev = train[~np.isnan(oof)]
        p = oof[~np.isnan(oof)]
        for thr in THR_GRID:
            r = season_report(ev, p >= thr)
            row = dict(mb=mb, thr=thr, score=season_score(r),
                       in_recall=r["in_season"]["recall"], in_fire_recall=r["in_season"]["fire_recall"],
                       in_removed=r["in_season"]["nonfire_removed"],
                       off_recall=r["off_season"]["recall"], off_fire_recall=r["off_season"]["fire_recall"],
                       off_removed=r["off_season"]["nonfire_removed"])
            log.append(row)
            print("   ", {k: round(v, 3) if isinstance(v, float) else v for k, v in row.items()}, flush=True)
    best = max(log, key=lambda r: r["score"])
    pd.DataFrame(log).to_csv(OUT / "v4_cv.csv", index=False)
    return best, log


# --------------------------------------------------------------------------- #
def by_month(df: pd.DataFrame, prob: np.ndarray, thr: float) -> dict:
    out = {}
    for m in range(1, 13):
        mm = (df.time.dt.month == m).values
        pos = mm & (df.label.values == 1)
        neg = mm & (df.label.values == 0)
        fires = df[pos].assign(k=prob[pos] >= thr).groupby("fire_name")["k"].max()
        out[m] = {"fire_detections": int(pos.sum()), "kept": float((prob[pos] >= thr).mean()) if pos.any() else None,
                  "fires": int(len(fires)), "fires_caught": int(fires.sum()),
                  "nonfire_removed": float((prob[neg] < thr).mean()) if neg.any() else None}
    return out


def named(df: pd.DataFrame, prob: np.ndarray, thr: float, names) -> dict:
    out = {}
    for n in names:
        m = df.fire_name.fillna("").str.upper().str.endswith(":" + n.upper()).values
        if m.any():
            out[n] = {"detections": int(m.sum()), "kept": float((prob[m] >= thr).mean()),
                      "median_prob": float(np.median(prob[m]))}
    return out


def main() -> None:
    grids = load_static()
    if not V3_BIN.exists():
        V3_BIN.write_bytes(BIN.read_bytes())
    v3_thr = 0.6
    print("building features", flush=True)
    train = training_set(TRAIN_YEARS, grids)
    print(f"train {TRAIN_YEARS}: {len(train):,} rows ({(train.copy_w == 1).sum():,} originals), "
          f"{train.label.mean():.1%} wildfire", flush=True)

    if "--skip-cv" in sys.argv and (OUT / "v4_cv.csv").exists():
        best = pd.read_csv(OUT / "v4_cv.csv").sort_values("score").iloc[-1].to_dict()
    else:
        best, _ = select(train)
    mb, thr = float(best["mb"]), float(best["thr"])
    print("chosen:", best, flush=True)

    tr = blank_static(train, 0.10, SEED)
    rf = make_rf(14, 30, 0.4).fit(Xn(tr), tr.label, sample_weight=weights(tr, mb))
    imp = pd.Series(rf.feature_importances_, index=FEATURES).sort_values(ascending=False)
    assert imp["month"] == 0.0, "month must not be used"

    results = {"chosen": {**best, "trees": 100, "depth": 14, "leaf": 30, "max_features": 0.4},
               "train_years": TRAIN_YEARS, "test_years": TEST_YEARS, "features": FEATURES,
               "feature_importance": imp.round(4).to_dict(), "test": {}}
    LA = ["Palisades", "Eaton", "Hughes", "Border 2", "Kenneth", "Mountain", "Franklin", "Park"]
    for y in TEST_YEARS:
        te = build(y, grids)
        p4 = rf.predict_proba(Xn(te))[:, 1]
        p3 = predict_like_swift(V3_BIN, X(te))
        results["test"][y] = {
            "v4": {**season_report(te, p4 >= thr), "auc": roc_auc_score(te.label, p4)},
            "v3": {**season_report(te, p3 >= v3_thr), "auc": roc_auc_score(te.label, p3)},
            "v4_by_month": by_month(te, p4, thr), "v3_by_month": by_month(te, p3, v3_thr),
            "named_fires_v4": named(te, p4, thr, LA), "named_fires_v3": named(te, p3, v3_thr, LA),
        }
        for s in ("MODIS", "VIIRS"):
            solo = build(y, grids, only=s)
            ps = rf.predict_proba(Xn(solo))[:, 1]
            results["test"][y][f"v4_{s}_only"] = season_report(solo, ps >= thr)["all"]
        nost = te.assign(**{b: np.nan for b in BANDS})
        results["test"][y]["v4_no_static"] = season_report(nost, rf.predict_proba(Xn(nost))[:, 1] >= thr)["all"]

    (OUT / "v4_results.json").write_text(json.dumps(results, indent=2, default=float))
    write_forest(rf, BIN)
    (OUT / "swift_threshold.txt").write_text(str(thr))
    te = build(2024, grids)
    check = predict_like_swift(BIN, X(te)[:20000])
    print(f"exported {BIN.name}: {BIN.stat().st_size / 1e6:.1f} MB, max |sklearn - exported| "
          f"{np.abs(check - rf.predict_proba(Xn(te[:20000]))[:, 1]).max():.1e} (app passes the real month)")

    # Swift parity golden file: the same 4-day window as before (14-17 Aug 2021), features recomputed
    t21 = build(2021, grids)
    win = t21[(t21.day >= "2021-08-14") & (t21.day <= "2021-08-17")]
    win = context_features(win[BASE_COLS])
    win = pd.concat([win, lookup(grids, win.lat.values, win.lon.values)], axis=1)
    win["prob"] = rf.predict_proba(Xn(win))[:, 1]
    win["time"] = win["time"].dt.strftime("%Y-%m-%d %H%M")
    win[["lat", "lon", "time", "sensor", "bright_mir", "bright_tir", "frp", "scan", "track", "is_day",
         "conf_class", *CONTEXT, *BANDS, "prob"]].to_csv(OUT / "swift_golden.csv", index=False)

    def row(name, r):
        return (f"{name:<22} recall {r['recall']:.3f} precision {r['precision']:.3f} removed {r['nonfire_removed']:.3f} "
                f"fires {r['fires_caught']}/{r['fires']} {r['by_size']}")
    for y in TEST_YEARS:
        print(f"\n=== {y} (never seen) ===")
        for v in ("v3", "v4"):
            for part in ("all", "in_season", "off_season"):
                r = results["test"][y][v][part]
                if r:
                    print(row(f"{v} {part}", r))
        print("named v3:", {k: round(v["kept"], 2) for k, v in results["test"][y]["named_fires_v3"].items()})
        print("named v4:", {k: round(v["kept"], 2) for k, v in results["test"][y]["named_fires_v4"].items()})
    print("\nTop features:\n" + imp.head(12).round(3).to_string())


if __name__ == "__main__":
    main()
