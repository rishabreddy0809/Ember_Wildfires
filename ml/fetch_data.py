"""Download the raw data for any year: FIRMS MODIS + VIIRS (S-NPP) archive detections
clipped to a California bounding box, and CAL FIRE FRAP fire perimeters.

No API key needed. Usage:
  uv run --project ml python ml/fetch_data.py 2020 2021            # train/test years
  uv run --project ml python ml/fetch_data.py --history 2017 2018 2019   # full-US files for burn history
  FIRMS_MAP_KEY=... uv run --project ml python ml/fetch_data.py --noaa20 2023   # NOAA-20 VIIRS via the API

Writes ml/data/raw/firms/{modis,viirs}_{YEAR}.csv and ml/data/raw/perimeters/perimeters_{YEAR}.geojson,
or with --history, ml/data/raw/history/{modis,viirs-snpp}_{YEAR}_US.csv.
"""

from __future__ import annotations

import argparse
import csv
import io
import json
import time
import urllib.parse
import urllib.request
from pathlib import Path

RAW = Path(__file__).resolve().parent / "data" / "raw"
FIRMS = "https://firms.modaps.eosdis.nasa.gov/data/country/{p}/{y}/{p}_{y}_United_States.csv"
PRODUCTS = {"modis": "modis", "viirs": "viirs-snpp"}
CA_BOX = (-124.5, 32.5, -114.0, 42.1)   # west, south, east, north
FRAP = ("https://services1.arcgis.com/jUJYIo9tSA7EHvfZ/arcgis/rest/services/"
        "California_Historic_Fire_Perimeters/FeatureServer/0/query")


def get(url: str, tries: int = 4) -> bytes:
    for i in range(tries):
        try:
            return urllib.request.urlopen(url, timeout=600).read()
        except Exception:
            if i == tries - 1:
                raise
            time.sleep(5 * (i + 1))


def firms_year(year: int) -> None:
    out_dir = RAW / "firms"
    out_dir.mkdir(parents=True, exist_ok=True)
    w, s, e, n = CA_BOX
    for name, product in PRODUCTS.items():
        text = get(FIRMS.format(p=product, y=year)).decode()
        rows = list(csv.DictReader(io.StringIO(text)))
        if not rows or "latitude" not in rows[0]:
            raise RuntimeError(f"unexpected FIRMS response for {product} {year}: {text[:200]!r}")
        keep = [r for r in rows if s <= float(r["latitude"]) <= n and w <= float(r["longitude"]) <= e
                and r["acq_date"].startswith(str(year))]
        path = out_dir / f"{name}_{year}.csv"
        with open(path, "w", newline="") as f:
            wr = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            wr.writeheader()
            wr.writerows(keep)
        print(f"{path.name}: {len(keep):,} detections")


def firms_history(year: int) -> None:
    out_dir = RAW / "history"
    out_dir.mkdir(parents=True, exist_ok=True)
    for product in PRODUCTS.values():
        path = out_dir / f"{product}_{year}_US.csv"
        path.write_bytes(get(FIRMS.format(p=product, y=year)))
        print(f"{path.name}: {path.stat().st_size / 1e6:.0f} MB")


def firms_api_year(year: int, source: str, key: str) -> None:
    """A whole year from the FIRMS area API in 5-day requests (for products with no yearly file)."""
    import datetime as dt
    out_dir = RAW / "firms"
    w, s, e, n = CA_BOX
    day, end, header, rows = dt.date(year, 1, 1), dt.date(year, 12, 31), None, []
    while day <= end:
        span = min(5, (end - day).days + 1)
        url = f"https://firms.modaps.eosdis.nasa.gov/api/area/csv/{key}/{source}/{w},{s},{e},{n}/{span}/{day}"
        text = get(url).decode()
        lines = text.strip().splitlines()
        if not lines or not lines[0].startswith("latitude"):
            raise RuntimeError(f"FIRMS API error for {source} {day}: {text[:120]!r}")
        header = header or lines[0]
        rows += lines[1:]
        day += dt.timedelta(days=span)
        time.sleep(0.3)
    path = out_dir / f"{source.lower()}_{year}.csv"
    path.write_text("\n".join([header, *sorted(set(rows))]) + "\n")
    print(f"{path.name}: {len(set(rows)):,} detections")


def perimeters_year(year: int) -> None:
    out_dir = RAW / "perimeters"
    out_dir.mkdir(parents=True, exist_ok=True)
    feats, offset = [], 0
    while True:
        q = dict(where=f"YEAR_={year}", outFields="*", outSR=4326, f="geojson", maxAllowableOffset=0.0005,
                 geometryPrecision=5, orderByFields="OBJECTID", resultOffset=offset, resultRecordCount=200)
        page = json.loads(get(FRAP + "?" + urllib.parse.urlencode(q)))
        fs = page.get("features", [])
        feats += fs
        offset += len(fs)
        more = page.get("exceededTransferLimit") or page.get("properties", {}).get("exceededTransferLimit")
        if not fs or not more:
            break
    path = out_dir / f"perimeters_{year}.geojson"
    path.write_text(json.dumps({"type": "FeatureCollection", "features": feats}, separators=(",", ":")))
    print(f"{path.name}: {len(feats)} perimeters")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("years", type=int, nargs="+")
    ap.add_argument("--history", action="store_true", help="full-US FIRMS files for the burn-history grid")
    ap.add_argument("--noaa20", action="store_true", help="NOAA-20 VIIRS standard product via the API (needs FIRMS_MAP_KEY)")
    args = ap.parse_args()
    for y in args.years:
        if args.noaa20:
            import os
            firms_api_year(y, "VIIRS_NOAA20_SP", os.environ["FIRMS_MAP_KEY"])
        elif args.history:
            firms_history(y)
        else:
            firms_year(y)
            perimeters_year(y)


if __name__ == "__main__":
    main()
