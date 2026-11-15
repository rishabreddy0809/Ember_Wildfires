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
| `img/ember-app.jpg`, `img/ember-app-1200.jpg` | Screenshot of the real Ember app (two sizes; the browser picks one) |
| `data/fires.pack` | Every MODIS + NOAA-20 VIIRS detection from one 24-hour FIRMS global file (packed by `tools/pack.py`) |
| `data/land.pack` | Dots on land for the globe (from Natural Earth, public domain) |
| `data/meta.json` | Counts and dates shown on the page |
| `vendor/three/` | three.js r170 (MIT license) |
| `tools/pack.py` | Shrinks the data files to about 30% (sorting, delta coding, gzip); `js/lib.js` unpacks them |

## Things to edit
Search index.html for `✏️` to find the spots meant for you:
- **Roadmap:** adjust the "Next" items to your real plans.
- **Team:** add teammates or a line about yourself.

## Publish on GitHub Pages
1. Create a new public repository on github.com (for example `wildfire-research`).
2. Upload the **contents** of this `website` folder so `index.html` is at the top level.
   Don't upload the Mac app folder, because your NASA key is in it.
3. Repo → Settings → Pages → "Deploy from a branch" → `main`, `/ (root)` → Save.
4. In a minute or two the site is live at `https://<your-username>.github.io/wildfire-research/`.
