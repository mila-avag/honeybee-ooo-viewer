# Honeybee viewer

Four screens for Honeybee L1 delivery work.

Open https://mila-avag.github.io/honeybee-ooo-viewer/

- **Link check.** Drop a delivery sheet. Get model names, links, and a flag for each side: OK, WRONG LINK, MISSING LINK, or NO LINK AVAILABLE.
- **Merge files.** Two or more CSVs become one row per task. The later file wins.
- **Upload sheet.** Check a task-upload CSV before it is uploaded.
- **Batch progress.** Refresh loads how many latest attempts of each model pair sit in each review layer.

Link check and merge work in the browser. Refresh needs the local proxy on your laptop (`python3 honeybee_viewer_server.py` in `honeybee_qc/ooo_handoff/viewer`), then open http://127.0.0.1:8765. The Redash key stays on the laptop.
