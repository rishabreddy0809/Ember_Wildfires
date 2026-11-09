# Project website

The demo site for **Ember**, a NASA Space Apps Challenge project (originally a science fair project,
"Clustering vs. Machine Learning: Identifying Real Wildfires from Harmonized MODIS and VIIRS Satellite Data"). It's built with HTML, CSS, JavaScript and three.js
(stored in `vendor/`), and needs no build step.

## Preview on your Mac
The 3D globe loads its data with `fetch`, so open the site through a local server, not by double-clicking:
```
cd ~/Desktop/"science fair"/website
python3 -m http.server 8000
```
Then open http://localhost:8000. Press Ctrl-C in Terminal to stop.

## What's in here
| Path | What it is |
|---|---|
| `index.html` | All the page text |
| `css/style.css` | Colors, fonts, layout |
| `js/globe.js` | The 3D Earth with real FIRMS detections (top of the page) |
| `js/scan.js` | 3D satellite scan / pixel-size demo |
| `js/cube.js` | 3D space-time cube DBSCAN demo |
| `js/appmock.js` | Interactive Ember app preview (real detections by region, click to inspect) |
| `js/main.js` | Navigation, counters, Random Forest demo, starts the 3D scenes |
| `data/fires.bin` | Every MODIS + NOAA-20 VIIRS detection from one 24-hour FIRMS global file (packed) |
| `data/land.bin` | Dots on land for the globe (from Natural Earth, public domain) |
| `data/meta.json` | Counts and dates shown on the page |
| `vendor/three/` | three.js r170 (MIT license) |

## Things to edit
Search index.html for `✏️` to find the spots meant for you:
- **Hero badge:** add your team name or Space Apps location.
- **Results:** replace the "Experiment in progress" pill once the experiment is done.
- **Roadmap:** adjust the "Next" items to your real plans.
- **Team:** add teammates or a line about yourself.

## Publish on GitHub Pages
1. Create a new public repository on github.com (for example `wildfire-research`).
2. Upload the **contents** of this `website` folder so `index.html` is at the top level.
   Don't upload the Mac app folder, because your NASA key is in it.
3. Repo → Settings → Pages → "Deploy from a branch" → `main`, `/ (root)` → Save.
4. In a minute or two the site is live at `https://<your-username>.github.io/wildfire-research/`.
