#!/usr/bin/env python3
"""Honeybee viewer. Serves the page and runs the allowlisted Redash queries.

Usage:
  python3 honeybee_viewer_server.py            # http://127.0.0.1:8765
  HOST=0.0.0.0 PORT=8080 python3 honeybee_viewer_server.py

Redash access comes from the REDASH_API_KEY environment variable. A local
file is only a fallback for someone running their own copy. The key is never
printed, logged, or sent to the browser.

Only the Honeybee viewer queries can run, and project_id is pinned to
6a567b80aaa4d140131eae6c. Python stdlib only.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

REDASH = os.environ.get("REDASH_URL", "https://redash.scale.com").rstrip("/")
PROJECT_ID = "6a567b80aaa4d140131eae6c"
ALLOWED = {
    400627: ("project_id", "task_ids"),
    400628: ("project_id",),
    400629: ("project_id",),
    400630: ("project_id", "task_ids"),
    400631: ("project_id", "task_ids"),
    400632: ("project_id",),
    400633: ("project_id", "task_ids"),
    400634: ("project_id", "exclude_ids"),
    400635: ("project_id",),
    400636: ("project_id", "task_ids"),
    400637: ("project_id",),
    390037: (),
    400607: ("task_ids",),
}
HEX24 = re.compile(r"[0-9a-fA-F]{24}")
HERE = Path(__file__).resolve().parent
SQL_NAMES = ("task_upload.sql", "batch_progress.sql", "ultra_deliveries.sql")
TIMEOUT_S = 1200
# Query ids already created under this Redash key. A fresh host uses them
# so the first Load saved result does not scan Snowflake again.
SEED_QUERIES = {
    "honeybee-viewer::batch-progress-nodes": 401443,
    "honeybee-viewer::deliveries::60": 401444,
    "honeybee-viewer::task-upload": 400807,
}


def page_file() -> Path:
    for path in (HERE / "honeybee_viewer.html", HERE / "index.html"):
        if path.exists():
            return path
    raise FileNotFoundError("missing viewer page")


def resolve_sql(name: str) -> Path | None:
    if name not in SQL_NAMES:
        return None
    for path in (HERE / "sql" / name, HERE / name):
        if path.exists():
            return path
    return None


def cache_file() -> Path:
    chosen = os.environ.get("QUERY_CACHE", "").strip()
    if chosen:
        return Path(chosen)
    home = Path.home() / ".cursor" / "redash_query_cache.json"
    if home.exists():
        return home
    return Path("/tmp/honeybee_query_cache.json")


def load_key() -> str:
    key = os.environ.get("REDASH_API_KEY", "").strip()
    if key:
        return key
    env = Path.home() / ".cursor" / "redash.env"
    if env.exists():
        for line in env.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line.startswith("export "):
                line = line[7:]
            if "=" in line:
                name, value = line.split("=", 1)
                if name.strip() in ("REDASH_API_KEY", "REDASH_KEY", "API_KEY"):
                    return value.strip().strip('"').strip("'")
    return ""


KEY = load_key()
JOBS = {}
JOBS_LOCK = threading.Lock()


def start_job(work) -> str:
    job_id = uuid.uuid4().hex
    with JOBS_LOCK:
        JOBS[job_id] = {"status": "running"}
        if len(JOBS) > 30:
            for old in list(JOBS)[:-30]:
                JOBS.pop(old, None)

    def run():
        try:
            result = work()
            with JOBS_LOCK:
                JOBS[job_id] = {"status": "done", "result": result}
        except Exception as err:
            with JOBS_LOCK:
                JOBS[job_id] = {"status": "error", "error": str(err)}

    threading.Thread(target=run, daemon=True).start()
    return job_id


def redash(method: str, path: str, body: dict | None = None) -> dict:
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(REDASH + path, data=data, method=method)
    req.add_header("Authorization", "Key " + KEY)
    req.add_header("Content-Type", "application/json")
    # Cloudflare rejects urllib's default agent with error 1010.
    req.add_header("User-Agent", "Mozilla/5.0")
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        # Never echo request headers; Redash error bodies don't contain the key.
        raise RuntimeError(f"Redash HTTP {err.code} on {path}") from None


def clean_ids(value: str) -> str:
    seen, out = set(), []
    for m in HEX24.findall(value or ""):
        t = m.lower()
        if t not in seen:
            seen.add(t)
            out.append(t)
    return ",".join(out)


def rows_from_result(result: dict) -> dict:
    data = result["data"]
    cols = [c["name"] for c in data["columns"]]
    rows = [[r.get(c) for c in cols] for r in data["rows"]]
    return {"columns": cols, "rows": rows, "retrieved_at": result.get("retrieved_at")}


def result_age_seconds(retrieved_at: str | None) -> float | None:
    if not retrieved_at:
        return None
    ts = datetime.fromisoformat(retrieved_at.replace("Z", "+00:00"))
    return (datetime.now(timezone.utc) - ts).total_seconds()


def latest_result(qid: int) -> dict | None:
    meta = redash("GET", f"/api/queries/{qid}")
    rid = meta.get("latest_query_data_id")
    if not rid:
        return None
    body = redash("GET", f"/api/query_results/{rid}")
    result = body.get("query_result") or body
    return result if result.get("data") else None


def load_query_ids() -> dict:
    path = cache_file()
    found = {}
    if path.exists():
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(raw, dict):
                found = {str(k): int(v) for k, v in raw.items() if str(v).isdigit() or isinstance(v, int)}
        except (OSError, ValueError, TypeError, json.JSONDecodeError):
            found = {}
    for key, qid in SEED_QUERIES.items():
        found.setdefault(key, qid)
    return found


def save_query_id(cache_key: str, qid: int) -> None:
    path = cache_file()
    current = {}
    if path.exists():
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(raw, dict):
                current = raw
        except (OSError, ValueError, TypeError, json.JSONDecodeError):
            current = {}
    current[cache_key] = qid
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(current, indent=2, sort_keys=True), encoding="utf-8")


def cached_result(cache_key: str, max_age: int):
    if max_age <= 0:
        return None
    saved_id = load_query_ids().get(cache_key)
    if not saved_id:
        return None
    result = latest_result(int(saved_id))
    age = result_age_seconds((result or {}).get("retrieved_at")) if result else None
    if result and (age is None or age <= max_age):
        return rows_from_result(result)
    return None


def run_sql(sql: str, *, data_source_id: int, cache_key: str, name: str) -> dict:
    """Create or update one saved query under this key, then refresh it.

    Does not edit anyone else's saved query. The browser never sees the SQL
    source or the Redash credential.
    """
    qid = load_query_ids().get(cache_key)
    if not qid:
        created = redash("POST", "/api/queries", {
            "name": name,
            "query": sql,
            "data_source_id": data_source_id,
            "schedule": None,
            "options": {"parameters": []},
        })
        qid = int(created["id"])
        redash("POST", f"/api/queries/{qid}", {"is_draft": False})
        save_query_id(cache_key, qid)
    else:
        redash("POST", f"/api/queries/{qid}", {"query": sql})
    started = redash("POST", f"/api/queries/{qid}/refresh", {})
    job_id = started["job"]["id"]
    deadline = time.time() + TIMEOUT_S
    while True:
        job = redash("GET", f"/api/jobs/{job_id}")["job"]
        if job["status"] == 3:
            rid = job["query_result_id"]
            body = redash("GET", f"/api/query_results/{rid}")
            result = body.get("query_result") or body
            return rows_from_result(result)
        if job["status"] in (4, 5):
            raise RuntimeError(job.get("error") or "Redash job failed")
        if time.time() > deadline:
            raise RuntimeError("timed out waiting for Redash")
        time.sleep(2)


def run_sql_text(sql: str, *, data_source_id: int, cache_key: str, name: str) -> dict:
    return run_sql(sql, data_source_id=data_source_id, cache_key=cache_key, name=name)


def run_batch_progress(max_age: int) -> dict:
    """Current review layer per model pair.

    Uses the same latest-node and metadata names as the deliveries query.
    A saved result comes back immediately. max_age 0 reruns the scan.
    """
    cache_key = "honeybee-viewer::batch-progress-nodes"
    cached = cached_result(cache_key, max_age)
    if cached:
        return cached
    sql_path = resolve_sql("batch_progress.sql")
    if sql_path is None:
        raise RuntimeError("batch progress SQL is missing")
    return run_sql_text(
        sql_path.read_text(encoding="utf-8"),
        data_source_id=22,
        cache_key=cache_key,
        name="Honeybee viewer — batch progress",
    )


def run_deliveries(max_age: int, days: int) -> dict:
    """Ultra deliveries pivot for a lookback window. Datasource 22.

    Does not edit saved query 390037. Each window has its own saved result.
    """
    if days < 1 or days > 365:
        raise RuntimeError("lookback must be between 1 and 365 days")
    cache_key = f"honeybee-viewer::deliveries::{days}"
    cached = cached_result(cache_key, max_age)
    if cached:
        return cached
    sql_path = resolve_sql("ultra_deliveries.sql")
    if sql_path is None:
        raise RuntimeError("deliveries SQL is missing")
    sql = sql_path.read_text(encoding="utf-8").replace("{{lookback_days}}", str(days))
    if "{{lookback_days}}" in sql:
        raise RuntimeError("lookback placeholder was not replaced")
    return run_sql_text(
        sql,
        data_source_id=22,
        cache_key=cache_key,
        name=f"Honeybee viewer — deliveries {days}d",
    )


def run_saved_results(qid: int, max_age: int) -> dict:
    started = redash("POST", f"/api/queries/{qid}/results", {"parameters": {}, "max_age": max_age})
    if "query_result" in started:
        result = started["query_result"]
    else:
        job_id = started["job"]["id"]
        deadline = time.time() + TIMEOUT_S
        while True:
            job = redash("GET", f"/api/jobs/{job_id}")["job"]
            if job["status"] == 3:
                result = redash("GET", f"/api/query_results/{job['query_result_id']}")["query_result"]
                break
            if job["status"] in (4, 5):
                raise RuntimeError(job.get("error") or "Redash job failed")
            if time.time() > deadline:
                raise RuntimeError("timed out waiting for Redash")
            time.sleep(2)
    return rows_from_result(result)


def run_task_upload(raw_ids: str) -> dict:
    """Query 400607 with the pasted task ids. Datasource 30, same SQL.

    The saved query has the ids written into the SQL, so this substitutes a
    new list and runs it as this key's own query. It does not edit 400607.
    """
    ids = [part for part in clean_ids(raw_ids).split(",") if part]
    if not ids:
        raise RuntimeError("paste at least one 24-character task id")
    if len(ids) > 5000:
        raise RuntimeError("paste at most 5000 task ids at once")
    sql_path = resolve_sql("task_upload.sql")
    if sql_path is None:
        raise RuntimeError("task upload SQL is missing")
    sql = sql_path.read_text(encoding="utf-8")
    sql = sql.replace("{{task_ids}}", ",".join(f"'{task_id}'" for task_id in ids))
    return run_sql_text(
        sql,
        data_source_id=30,
        cache_key="honeybee-viewer::task-upload",
        name="Honeybee viewer — task upload",
    )


def run_query(qid: int, params: dict, max_age: int = 0) -> dict:
    if qid == 390037:
        try:
            days = int(params.get("lookback_days") or 60)
        except (TypeError, ValueError):
            days = 60
        return run_deliveries(max_age, days)
    if qid == 400628:
        return run_batch_progress(max_age)
    if qid == 400607:
        return run_task_upload(str(params.get("task_ids", "")))
    allowed = ALLOWED[qid]
    p = {"project_id": PROJECT_ID}
    for name in allowed:
        if name in ("task_ids", "exclude_ids"):
            p[name] = clean_ids(str(params.get(name, "")))
    started = redash("POST", f"/api/queries/{qid}/results", {"parameters": p, "max_age": 0})
    if "query_result" in started:
        result = started["query_result"]
    else:
        job_id = started["job"]["id"]
        deadline = time.time() + TIMEOUT_S
        while True:
            job = redash("GET", f"/api/jobs/{job_id}")["job"]
            if job["status"] == 3:
                result = redash("GET", f"/api/query_results/{job['query_result_id']}")["query_result"]
                break
            if job["status"] in (4, 5):
                raise RuntimeError(job.get("error") or "Redash job failed")
            if time.time() > deadline:
                raise RuntimeError("timed out waiting for Redash")
            time.sleep(2)
    data = result["data"]
    cols = [c["name"] for c in data["columns"]]
    rows = [[r.get(c) for c in cols] for r in data["rows"]]
    return {"columns": cols, "rows": rows}


GITHUB_ORIGIN = "https://mila-avag.github.io"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # quiet, and never logs headers
        sys.stderr.write("%s %s\n" % (self.command, self.path.split("?")[0]))

    def _origin_ok(self) -> bool:
        origin = self.headers.get("Origin")
        port = self.server.server_port
        host = self.headers.get("Host", "")
        allowed = {
            None,
            f"http://127.0.0.1:{port}",
            f"http://localhost:{port}",
            GITHUB_ORIGIN,
            f"https://{host}",
            f"http://{host}",
        }
        extra = os.environ.get("ALLOWED_ORIGINS", "")
        allowed.update(part.strip() for part in extra.split(",") if part.strip())
        return origin in allowed

    def _cors(self) -> None:
        origin = self.headers.get("Origin")
        if not origin:
            return
        self.send_header("Access-Control-Allow-Origin", origin)
        self.send_header("Vary", "Origin")
        self.send_header("Access-Control-Allow-Private-Network", "true")

    def _json(self, code: int, obj: dict):
        body = json.dumps(obj, default=str).encode()
        self.send_response(code)
        self._cors()
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        if not self._origin_ok():
            return self._json(403, {"error": "origin not allowed"})
        self.send_response(204)
        self._cors()
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path.startswith("/api/health"):
            return self._json(200, {"ok": True, "key_loaded": bool(KEY), "project_id": PROJECT_ID})
        if path.startswith("/api/jobs/"):
            if not self._origin_ok():
                return self._json(403, {"error": "origin not allowed"})
            job_id = path[len("/api/jobs/"):]
            with JOBS_LOCK:
                job = JOBS.get(job_id)
            if not job:
                return self._json(404, {"error": "job not found"})
            if job["status"] == "done":
                body = {"status": "done"}
                body.update(job["result"])
                return self._json(200, body)
            if job["status"] == "error":
                return self._json(200, {"status": "error", "error": job["error"]})
            return self._json(200, {"status": "running"})
        if path in ("/", "/index.html", "/honeybee_viewer.html"):
            body = page_file().read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            return self.wfile.write(body)
        if path.startswith("/sql/"):
            sql_path = resolve_sql(path[len("/sql/"):])
            if sql_path is None:
                return self._json(404, {"error": "not found"})
            body = sql_path.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            return self.wfile.write(body)
        self._json(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/api/run":
            return self._json(404, {"error": "not found"})
        if not self._origin_ok():
            return self._json(403, {"error": "origin not allowed"})
        try:
            req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
            qid = int(req.get("qid"))
        except Exception:
            return self._json(400, {"error": "bad request"})
        if qid not in ALLOWED:
            return self._json(400, {"error": f"q {qid} is not available from this viewer"})
        params = req.get("params") or {}
        if params.get("project_id", PROJECT_ID) != PROJECT_ID:
            return self._json(400, {"error": f"project_id is pinned to {PROJECT_ID}"})
        try:
            max_age = int(req.get("max_age") or 0)
        except (TypeError, ValueError):
            max_age = 0
        if max_age < 0:
            max_age = 0
        if not KEY:
            return self._json(400, {"error": "Redash access is not set up"})
        job_id = start_job(lambda: run_query(qid, params, max_age))
        return self._json(202, {"job_id": job_id, "status": "running"})


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default=os.environ.get("HOST", "127.0.0.1"))
    ap.add_argument("--port", type=int, default=int(os.environ.get("PORT", "8765")))
    args = ap.parse_args()
    try:
        page_file()
    except FileNotFoundError as err:
        sys.exit(str(err))
    print(f"Honeybee viewer → http://{args.host}:{args.port}")
    print("Redash access: " + ("ready" if KEY else "not set up (CSV tools only)"))
    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
