# Ember: Active Fire Detection Viewer

A macOS app that downloads NASA FIRMS satellite fire detections from **MODIS** and **VIIRS**
for the whole world and shows each one exactly as reported, with no clustering or merging.

It opens on a 3D globe with every fire of the last two days as a glowing ember. Three views share one window:

- **Globe**: turn it by dragging or flinging, scroll to zoom, click a fire or a region.
  MODIS fires burn orange and VIIRS fires light blue; brighter and larger means stronger.
- **Map**: the same detections on a flat MapKit map, with a per-hour timeline.
- **Model**: how the wildfire classifier works and what it makes of the loaded data.

The left card lists where it is burning, by region, busiest first. The right card describes
whatever is selected: the world, a region, or one detection. The request card at the top left
changes the area (whole world, a continent, a preset, or your own box), dates and satellite.

## 1. Add your MAP_KEY

1. Request a free key at <https://firms.modaps.eosdis.nasa.gov/api/map_key/> (it's emailed to you).
2. Open `MyApp/Secrets.plist` and replace `PASTE_YOUR_MAP_KEY_HERE` with your key.
   (If that file is missing, copy `Secrets.example.plist` from the project root to `MyApp/Secrets.plist`.)
3. Build and run in Xcode.

`MyApp/Secrets.plist` is listed in `.gitignore`, so your key never ends up in git.
Settings (⌘,) shows whether the key was found.

## 2. Use it

| Action | Shortcut |
|---|---|
| Refresh | ⌘R |
| Download with the current request | ⌘↩ |
| Cancel download | ⌘. |
| Export combined CSV | ⌘E |
| Show/hide MODIS, VIIRS | ⌘1, ⌘2 |
| Harmonized ML filter (wildfires only) | ⌘3 |
| Globe, Map, Model | ⌥⌘1, ⌥⌘2, ⌥⌘3 |
| Next / previous region | ⌘↓, ⌘↑ |
| Zoom to area | ⌘0 |
| Show/hide details | ⌥⌘I |
| Step through overlapping detections | [ and ] |
| Clear selection | Esc |

The **Show** buttons switch between both sensors (raw), MODIS only, VIIRS only, and
**Wildfires**. Wildfires mode shows both sensors and hides detections that a random forest trained on
harmonized MODIS + VIIRS data judges are not wildfire: farm and prescribed burns, industrial heat,
and false alarms. On California 2021 it removed 92% of non-wildfire detections at 99% precision, and caught
126 of 168 mapped fires, including 49 of 77 fires with fewer than 5 detections. On 2022 and
2023, which it never saw, accuracy was 93% and 90%; guessing "wildfire" every time gets 45%. It
keeps working if MODIS or VIIRS goes offline. A
**Sensitivity** slider trades catching more small fires against removing more false alarms. The details card shows each detection's wildfire probability. The filter changes
only what is drawn; the cache and CSV export are unchanged. See `ml/README.md` for how the model was built.

**The model was trained on California only**, and its land-cover inputs cover only California.
Elsewhere treat its answer as a rough guide: on a typical worldwide download it calls about 2%
of detections wildfire, which says more about the model than about the fires.

Click any point to see every FIRMS column for it. If several detections overlap under the
cursor, the details card lists all of them, one at a time.

A worldwide two-day download is about 100,000 detections (roughly 8 MB). The last download is
kept on disk, so the app opens with data even when offline.

## 3. Load the export in Python

```python
import pandas as pd
df = pd.read_csv("firms_California_2026-11-06_to_2026-11-07.csv", parse_dates=["acq_datetime_utc"])
modis = df[df.sensor == "MODIS"]   # use confidence_percent (0–100)
viirs = df[df.sensor == "VIIRS"]   # use confidence_category (low / nominal / high)
```

## FIRMS API facts used (checked Nov 2026)

- Endpoint: `/api/area/csv/[MAP_KEY]/[SOURCE]/[west,south,east,north]/[DAY_RANGE]/[DATE]`
- `DAY_RANGE` is 1–5. Longer ranges (up to 10 days in Ember) are split into several requests.
- Sources: `MODIS_NRT`, `MODIS_SP`, `VIIRS_SNPP_NRT/SP`, `VIIRS_NOAA20_NRT/SP`, `VIIRS_NOAA21_NRT/SP`
- Limit: 5,000 transactions per 10 minutes per key. Ember limits itself to 250 and waits 15 s between refreshes.
- **Suomi NPP stopped producing new FIRMS data on Nov 2, 2026.** That's why the VIIRS satellite
  defaults to NOAA-20, which has the same 375 m VIIRS instrument. Choose Suomi NPP in the sidebar
  to get its archive data from before that date.

## Code map

```
MyApp/
  Models/      FireDetection, FireQuery (area, dates, source names), WorldRegion (region names)
  Networking/  FIRMSClient (download), FIRMSError, RateLimiter
  Parsing/     CSVParser (generic), FIRMSParser (CSV → FireDetection)
  Processing/  DetectionProcessor ← add your future processing step here
  Storage/     DetectionCache (offline copy)
  Export/      CSVExporter
  Store/       FireStore (app state: download → parse → process → map)
  Globe/       SceneKit globe: Earth materials, and all fires drawn as one mesh
  Map/         MapKit view + fast single-overlay renderer
  ML/          WildfireClassifier (features + random forest, runs on every core)
  UI/          RootView, the three tabs, sidebar, details card, Theme + Components
               (the cream-card design system), menus, menu bar item, Settings
  Resources/   Earth textures, star field, Instrument Serif
```

Debug builds are compiled with optimisation on (`SWIFT_OPTIMIZATION_LEVEL = -O`): without it
the classifier takes about 40 s on a worldwide download instead of 0.2 s. Set it back to
`-Onone` in the build settings if you need to step through code in the debugger.

Credits: the Earth is NASA Blue Marble (day) and VIIRS Black Marble (city lights) via NASA
GIBS, with clouds cut from a real VIIRS true-colour day and relief from SRTM. The sky is the
NASA SVS Deep Star Map 2020. Instrument Serif is under the SIL Open Font License
(`Resources/InstrumentSerif-OFL.txt`).
