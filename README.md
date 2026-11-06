# Honeybee viewer

Six screens for Honeybee L1 delivery work. Open the Instructions tab for when to use each one.

Open https://mila-avag.github.io/honeybee-ooo-viewer/

- **Instructions.** When to use each tab, and what you need open.
- **Link check.** Drop a delivery sheet. Get model names, links, and a flag for each side: OK, WRONG LINK, MISSING LINK, or NO LINK AVAILABLE.
- **Merge files.** Two or more CSVs become one row per task. The later file wins.
- **Task upload.** Paste task ids and download the upload CSV. A test-accounts file fills the two logins so a row never reuses one account. Broken tasks are listed at the end: missing opening prompt, rubric, or target deliverables, or an aspirational task with no universe. Download query saves the SQL for data source 30.
- **Batch progress.** How many tasks of each model pair are in each open review layer. Download query saves the SQL for data source 22.
- **Ultra deliveries.** The pivot from query 390037, with every model pair included. Download query saves that SQL.

Link check and merge work in the browser. Refresh needs the local proxy on your laptop (`python3 honeybee_viewer_server.py` in `honeybee_qc/ooo_handoff/viewer`), then open http://127.0.0.1:8765. The Redash key stays on the laptop.
