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
| `img/ember-app.jpg` | Screenshot of the real Ember app, shown in the demo section |
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
