# Honeybee viewer

Six screens for Honeybee L1 delivery work. Open the Instructions tab for when to use each one.

Open https://honeybee-ooo-viewer.onrender.com/ or https://mila-avag.github.io/honeybee-ooo-viewer/

- **Instructions.** When to use each tab, and what you need open.
- **Link check.** Drop a delivery sheet. Get model names, links, and a flag for each side: OK, WRONG LINK, MISSING LINK, or NO LINK AVAILABLE.
- **Merge files.** Two or more CSVs become one row per task. The later file wins.
- **Task upload.** Paste task ids and download the upload CSV. A test-accounts file fills the two logins so a row never reuses one account. Broken tasks are listed at the end: missing opening prompt, rubric, or target deliverables, or an aspirational task with no universe. Download query saves the SQL for data source 30.
- **Batch progress.** How many tasks of each model pair are in each open review layer. It uses the same latest pending node and metadata names as deliveries. Model A and Model B filters hide rows in the table. Download query saves the SQL for data source 22.
- **Ultra deliveries.** The pivot from query 390037, with every model pair included. The window starts at 60 days and can be set to a number of weeks. Model A and Model B filters hide rows in the table. Download query saves that SQL.

Link check and merge work in the browser. Snowflake buttons (Build CSV, Load saved result, Recompute) run on the hosted app. Redash access is a repository secret named `REDASH_API_KEY`. It is not in the page or the repository.

To run a copy yourself, set `REDASH_API_KEY` and start `python3 honeybee_viewer_server.py`. It listens on http://127.0.0.1:8765.
