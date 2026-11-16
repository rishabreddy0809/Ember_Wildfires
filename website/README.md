# Project website

The demo site for **Ember**, a NASA Space Apps Challenge project that uses machine learning (a Random
Forest) to sort real wildfires from false alarms in combined MODIS and VIIRS data. It's built with HTML,
CSS, JavaScript and three.js (stored in `vendor/`), and needs no build step.

It has two parts:
- **The landing page** (`index.html`), described below.
- **The web app** (`app/`, opened by the "Try it out" button). It's a browser version of the Mac
  app's Globe view on live data: every fire NASA FIRMS saw in the last 48 hours, scored by the
  same wildfire model. `api/fires.js` is a Vercel function that downloads FIRMS's public global
  files (no key needed), scores every detection, and sends the result packed small. Vercel's CDN
  keeps each answer for 30 minutes, so NASA is asked at most twice an hour.

The landing page has three acts: the hook (a counter runs up while the day's fires switch on across the
planet), the explanation (a scroll story on the globe, then the problem and the method), and the demo
(a screenshot of the real app and an interactive preview).

## Preview on your Mac
The 3D globe loads its data with `fetch`, so open the site through a local server, not by double-clicking:
```
cd ~/Desktop/Ember_Wildfires/website
python3 -m http.server 8000
```
Then open http://localhost:8000. Press Ctrl-C in Terminal to stop.
The web app needs its API too, so preview it with `npx vercel dev` instead (it runs `api/` locally).
If the globe doesn't appear, reload the page: Python's built-in server sometimes drops a
connection when the page asks for many files at once. Real hosts (Vercel, GitHub Pages) don't.

## Keeping it fast
- The globe's data is packed by `tools/pack.py` (about 70% smaller) and unpacked in `js/lib.js`.
  To replace the data, write a new `.bin` in the format described in that script and run it.
- `index.html` preloads everything the opening globe needs, so it downloads in parallel.
- The app screenshot comes in two sizes; phones and normal screens get the small one.

## What's in here
| Path | What it is |
|---|---|
| `index.html` | All the page text |
| `css/style.css` | Colors, fonts, layout |
| `js/globe.js` | The 3D Earth with real FIRMS detections: the opening "ignition" and the scroll story |
| `js/scan.js` | 3D satellite scan / pixel-size demo |
| `js/appmock.js` | Interactive Ember app preview (real detections by region, click to inspect) |
| `js/main.js` | Navigation, the opening counter, Random Forest demo, starts the 3D scenes |
| `js/calendar.js` | Harmonized fire calendar: one square per day, click a day to map its fire cells |
| `img/ember-app.jpg`, `img/ember-app-1200.jpg` | Screenshot of the real Ember app (two sizes; the browser picks one) |
| `data/fires.pack` | Every MODIS + NOAA-20 VIIRS detection from one 24-hour FIRMS global file (packed by `tools/pack.py`) |
| `data/land.pack` | Dots on land for the globe (from Natural Earth, public domain) |
| `data/meta.json` | Counts and dates shown on the page |
| `data/harmonized.json` | Daily harmonized fire cells for California 2024–2025 (from `ml/export_site_data.py`) |
| `img/agreement.png`, `img/park_fire.png` | Validation chart and Park Fire case study (from `ml/`) |
| `vendor/three/` | three.js r170 (MIT license) |
| `app/` | The web app: `index.html`, `app.css`, `js/globe.js` (3D Earth), `js/data.js` (download, regions, totals), `js/main.js` (panels) |
| `app/img/` | Earth textures: NASA Blue Marble (day), Black Marble (night lights), clouds |
| `api/fires.js` | Vercel function: live FIRMS data, scored and packed for the app |
| `api/_lib/classifier.js` | The wildfire model in JavaScript, a port of the Mac app's `WildfireClassifier.swift` |
| `api/_lib/parity.test.js` | Checks the port against Python on 18,943 detections: `node website/api/_lib/parity.test.js` |
| `api/_model/` | The trained forest and California land-cover grids (copies of `MyApp/ML/*.bin`) |
| `vercel.json` | Gives the function its model files, 60 s and 1 GB |
| `tools/pack.py` | Shrinks the data files to about 30% (sorting, delta coding, gzip); `js/lib.js` unpacks them |

## Updating the results
The Results section (`#results`) shows the harmonized MODIS + VIIRS record. Its charts and data are generated:
```
uv run --project ml python ml/harmonize.py 2024 2025
uv run --project ml python ml/validate.py 2024 2025
uv run --project ml python ml/plot_validation.py
uv run --project ml python ml/case_study.py
uv run --project ml python ml/export_site_data.py 2024 2025   # -> data/harmonized.json, img/agreement.png, img/park_fire.png
```
The headline numbers in `index.html` are typed in by hand; check them against `ml/outputs/harmonized/results.json`.

## Updating the web app's model
`api/_model/ember_rf.bin` and `ember_static.bin` are copies of `MyApp/ML/`. After retraining, copy them over, set
`THRESHOLD` in `api/_lib/classifier.js` and `app/js/data.js` to `ml/outputs/swift_threshold.txt`, and run
`node website/api/_lib/parity.test.js` from the repo root.

## Publish on GitHub Pages
1. Create a new public repository on github.com (for example `wildfire-research`).
2. Upload the **contents** of this `website` folder so `index.html` is at the top level.
   Don't upload the Mac app folder, because your NASA key is in it.
3. Repo → Settings → Pages → "Deploy from a branch" → `main`, `/ (root)` → Save.
4. In a minute or two the site is live at `https://<your-username>.github.io/wildfire-research/`.
