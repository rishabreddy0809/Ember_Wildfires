# Project website

The demo site for **Ember**, a NASA Space Apps Challenge project that uses machine learning (a Random
Forest) to sort real wildfires from false alarms in combined MODIS and VIIRS data. It's built with HTML,
CSS, JavaScript and three.js (stored in `vendor/`), and needs no build step.

The page has three acts: the hook (a counter runs up while the day's fires switch on across the
planet), the explanation (a scroll story on the globe, then the problem and the method), and the demo
(a screenshot of the real app and an interactive preview).

## Preview on your Mac
The 3D globe loads its data with `fetch`, so open the site through a local server, not by double-clicking:
```
cd ~/Desktop/Ember_Wildfires/website
python3 -m http.server 8000
```
Then open http://localhost:8000. Press Ctrl-C in Terminal to stop.

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
| `img/ember-app.jpg` | Screenshot of the real Ember app, shown in the demo section |
| `data/fires.bin` | Every MODIS + NOAA-20 VIIRS detection from one 24-hour FIRMS global file (packed) |
| `data/land.bin` | Dots on land for the globe (from Natural Earth, public domain) |
| `data/meta.json` | Counts and dates shown on the page |
| `data/harmonized.json` | Daily harmonized fire cells for California 2024–2025 (from `ml/export_site_data.py`) |
| `img/agreement.png`, `img/park_fire.png` | Validation chart and Park Fire case study (from `ml/`) |
| `vendor/three/` | three.js r170 (MIT license) |

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

## Publish on GitHub Pages
1. Create a new public repository on github.com (for example `wildfire-research`).
2. Upload the **contents** of this `website` folder so `index.html` is at the top level.
   Don't upload the Mac app folder, because your NASA key is in it.
3. Repo → Settings → Pages → "Deploy from a branch" → `main`, `/ (root)` → Save.
4. In a minute or two the site is live at `https://<your-username>.github.io/wildfire-research/`.
