"""Build the static context grids the v3 model uses, and the app's copy of them.

Two grids on a 0.01 deg (~1 km) lat/lon grid covering California (32.5-42.1 N, 124.5-114.0 W):

1. Land cover fractions from USGS NLCD 2019 (pre-dates both training and test years):
   forest, shrub, grass, agriculture, developed. Fetched from the MRLC WCS at 240 m.
2. Fire history: number of distinct months in 2017-2019 with any MODIS or VIIRS
   detection in the cell or its 8 neighbors. Farm burns and industrial heat sources
   recur in the same places every year; wildfires rarely do. 2017-2019 comes before
   both 2020 (train) and 2021 (test), so nothing leaks.

Writes ml/data/static/grids.npz and MyApp/ML/ember_static.bin.
Run:  uv run --project ml python ml/build_static_grids.py
"""

from __future__ import annotations

import struct
import zlib
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.request import urlopen

import numpy as np
import pandas as pd
import rasterio
from pyproj import Transformer

ROOT = Path(__file__).resolve().parent
RAW = ROOT / "data" / "raw"
OUT_NPZ = ROOT / "data" / "static" / "grids.npz"
OUT_BIN = ROOT.parent / "MyApp" / "ML" / "ember_static.bin"

LAT0, LON0, STEP, NROWS, NCOLS = 32.5, -124.5, 0.01, 960, 1050
BANDS = ["lc_forest", "lc_shrub", "lc_grass", "lc_ag", "lc_dev", "hist_months"]
NLCD_GROUPS = {"lc_forest": (41, 42, 43), "lc_shrub": (51, 52), "lc_grass": (71, 72),
               "lc_ag": (81, 82), "lc_dev": (21, 22, 23, 24)}
WCS = ("https://www.mrlc.gov/geoserver/mrlc_download/wcs?service=WCS&version=2.0.1&request=GetCoverage"
       "&coverageId=mrlc_download__NLCD_2019_Land_Cover_L48&subset=X({x0},{x1})&subset=Y({y0},{y1})"
       "&SCALEFACTOR=0.125&format=image/geotiff")


def cell_index(lat, lon):
    r = np.floor((np.asarray(lat) - LAT0) / STEP).astype(int)
    c = np.floor((np.asarray(lon) - LON0) / STEP).astype(int)
    ok = (r >= 0) & (r < NROWS) & (c >= 0) & (c < NCOLS)
    return r, c, ok


def fetch_tile(xy) -> Path:
    x0, y0 = xy
    path = RAW / "landcover" / f"nlcd2019_{x0}_{y0}.tif"
    if not path.exists():
        data = urlopen(WCS.format(x0=x0, x1=x0 + 200_000, y0=y0, y1=y0 + 200_000), timeout=300).read()
        if not data.startswith((b"II*", b"MM\x00*")):
            raise RuntimeError(f"tile {xy} is not a GeoTIFF: {data[:200]!r}")
        path.write_bytes(data)
    return path


def land_cover() -> dict[str, np.ndarray]:
    (RAW / "landcover").mkdir(parents=True, exist_ok=True)
    tiles = [(x, y) for x in range(-2_500_000, -1_400_000, 200_000) for y in range(1_200_000, 2_500_000, 200_000)]
    with ThreadPoolExecutor(6) as ex:
        paths = list(ex.map(fetch_tile, tiles))
    to_ll = Transformer.from_crs(5070, 4326, always_xy=True)
    total = np.zeros((NROWS, NCOLS), np.int64)
    counts = {k: np.zeros((NROWS, NCOLS), np.int64) for k in NLCD_GROUPS}
    for p in paths:
        with rasterio.open(p) as r:
            a = r.read(1)
            rows, cols = np.indices(a.shape)
            xs, ys = rasterio.transform.xy(r.transform, rows.ravel(), cols.ravel())
        valid = (a.ravel() > 0) & (a.ravel() < 250)
        lon, lat = to_ll.transform(np.asarray(xs)[valid], np.asarray(ys)[valid])
        cls = a.ravel()[valid]
        rr, cc, ok = cell_index(lat, lon)
        np.add.at(total, (rr[ok], cc[ok]), 1)
        for k, codes in NLCD_GROUPS.items():
            m = ok & np.isin(cls, codes)
            np.add.at(counts[k], (rr[m], cc[m]), 1)
    out = {}
    for k in NLCD_GROUPS:
        frac = np.where(total > 0, np.round(100 * counts[k] / np.maximum(total, 1)), 255)
        out[k] = frac.astype(np.uint8)            # 0-100 %, 255 = no data (ocean / outside NLCD)
    print(f"land cover: {int((total > 0).sum()):,} cells with data")
    return out


def fire_history() -> np.ndarray:
    months = np.zeros((NROWS, NCOLS, 36), bool)
    for f in sorted((RAW / "history").glob("*_US.csv")):
        df = pd.read_csv(f, usecols=["latitude", "longitude", "acq_date"])
        r, c, ok = cell_index(df.latitude.values, df.longitude.values)
        d = pd.to_datetime(df.acq_date[ok])
        m = ((d.dt.year - 2017) * 12 + d.dt.month - 1).values
        keep = (m >= 0) & (m < 36)
        months[r[ok][keep], c[ok][keep], m[keep]] = True
        print(f"history: {f.name} {int(ok.sum()):,} detections in grid")
    # any detection in the cell or its 8 neighbors (absorbs geolocation jitter)
    padded = np.pad(months, ((1, 1), (1, 1), (0, 0)))
    spread = np.zeros_like(months)
    for dr in (0, 1, 2):
        for dc in (0, 1, 2):
            spread |= padded[dr:dr + NROWS, dc:dc + NCOLS]
    return spread.sum(axis=2).astype(np.uint8)


def write_app_bin(grids: dict[str, np.ndarray]) -> None:
    """Little-endian: 'EMSG', u32 version, u32 rows, u32 cols, u32 bands, f64 lat0, f64 lon0,
    f64 step, then raw-DEFLATE (zlib wbits=-15) of the uint8 bands, band-major, row-major."""
    payload = b"".join(grids[b].tobytes() for b in BANDS)
    comp = zlib.compressobj(9, zlib.DEFLATED, -15)
    blob = comp.compress(payload) + comp.flush()
    OUT_BIN.write_bytes(b"EMSG" + struct.pack("<IIII3d", 1, NROWS, NCOLS, len(BANDS), LAT0, LON0, STEP) + blob)
    print(f"wrote {OUT_BIN} ({OUT_BIN.stat().st_size / 1e6:.1f} MB)")


def lookup(grids: dict[str, np.ndarray], lat, lon) -> pd.DataFrame:
    """Static features for points: land cover as 0-1 fractions, history in months; NaN outside the grid."""
    r, c, ok = cell_index(lat, lon)
    out = {}
    for b in BANDS:
        v = np.full(len(r), np.nan)
        raw = grids[b][r[ok], c[ok]].astype(float)
        if b != "hist_months":
            raw = np.where(raw == 255, np.nan, raw / 100)
        v[ok] = raw
        out[b] = v
    return pd.DataFrame(out)


def load_grids() -> dict[str, np.ndarray]:
    z = np.load(OUT_NPZ)
    return {b: z[b] for b in BANDS}


def main() -> None:
    grids = land_cover()
    grids["hist_months"] = fire_history()
    OUT_NPZ.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(OUT_NPZ, **grids)
    write_app_bin(grids)


if __name__ == "__main__":
    main()
