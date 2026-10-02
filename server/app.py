"""keystroke-sync: tiny sync backend for KeystrokeCounter.

Each Mac uploads its OWN per-day aggregate counts (keystrokes, clicks, key and
app frequency tallies) plus its own lifetime counters. Uploads are idempotent
replaces keyed by (device_id, date), never increments, so retries and repeated
syncs can't double-count. The response carries everything the OTHER devices
have contributed, summed, which the app adds to its local numbers for display.

Standard library only: http.server + sqlite3. One shared bearer token
(SYNC_TOKEN) guards every endpoint except /healthz.
"""

import hmac
import json
import os
import re
import sqlite3
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DB_PATH = os.environ.get("DB_PATH", "/data/sync.db")
TOKEN = os.environ.get("SYNC_TOKEN", "")
PORT = int(os.environ.get("PORT", "8080"))

MAX_BODY = 8 * 1024 * 1024
MAX_DAYS = 5000
MAX_MAP_ENTRIES = 2000
MAX_NAME_LEN = 200

DEVICE_ID_RE = re.compile(r"^[A-Za-z0-9-]{8,64}$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")

SCHEMA = """
CREATE TABLE IF NOT EXISTS devices (
    device_id   TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    keystrokes  INTEGER NOT NULL DEFAULT 0,
    clicks      INTEGER NOT NULL DEFAULT 0,
    since       TEXT,
    updated_at  INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS days (
    device_id      TEXT NOT NULL REFERENCES devices(device_id),
    date           TEXT NOT NULL,
    keystrokes     INTEGER NOT NULL,
    clicks         INTEGER NOT NULL,
    key_frequency  TEXT NOT NULL,
    app_frequency  TEXT NOT NULL,
    updated_at     INTEGER NOT NULL,
    PRIMARY KEY (device_id, date)
);
"""

# sqlite3 connections aren't shared across threads; one writer at a time keeps
# the replace-then-read of a sync atomic from the client's point of view.
db_lock = threading.Lock()


def connect():
    conn = sqlite3.connect(DB_PATH)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


class BadRequest(Exception):
    pass


def count(value, field):
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise BadRequest(f"{field} must be a non-negative integer")
    return value


def frequency_map(value, field):
    if not isinstance(value, dict) or len(value) > MAX_MAP_ENTRIES:
        raise BadRequest(f"{field} must be an object with at most {MAX_MAP_ENTRIES} entries")
    for name, n in value.items():
        if len(name) > MAX_NAME_LEN:
            raise BadRequest(f"{field} key too long")
        count(n, field)
    return value


def parse_sync(body):
    """Validate a sync upload. Returns (device_id, name, lifetime, days)."""
    if not isinstance(body, dict):
        raise BadRequest("body must be an object")

    device_id = body.get("deviceID")
    if not isinstance(device_id, str) or not DEVICE_ID_RE.match(device_id):
        raise BadRequest("invalid deviceID")

    name = body.get("deviceName") or "Mac"
    if not isinstance(name, str):
        raise BadRequest("invalid deviceName")

    lifetime = body.get("lifetime")
    if not isinstance(lifetime, dict):
        raise BadRequest("lifetime must be an object")
    since = lifetime.get("since")
    if since is not None and not isinstance(since, str):
        raise BadRequest("invalid lifetime.since")
    lifetime = (count(lifetime.get("keystrokes"), "lifetime.keystrokes"),
                count(lifetime.get("clicks"), "lifetime.clicks"),
                since)

    days = body.get("days", [])
    if not isinstance(days, list) or len(days) > MAX_DAYS:
        raise BadRequest(f"days must be a list of at most {MAX_DAYS}")
    parsed = []
    for d in days:
        if not isinstance(d, dict) or not isinstance(d.get("date"), str) or not DATE_RE.match(d["date"]):
            raise BadRequest("each day needs a YYYY-MM-DD date")
        parsed.append((d["date"],
                       count(d.get("keystrokes"), "keystrokes"),
                       count(d.get("clicks"), "clicks"),
                       frequency_map(d.get("keyFrequency", {}), "keyFrequency"),
                       frequency_map(d.get("appFrequency", {}), "appFrequency")))

    return device_id, name[:MAX_NAME_LEN], lifetime, parsed


def sync(body):
    device_id, name, (keystrokes, clicks, since), days = parse_sync(body)
    now = int(time.time())

    with db_lock:
        conn = connect()
        try:
            with conn:
                conn.execute(
                    """INSERT INTO devices (device_id, name, keystrokes, clicks, since, updated_at)
                       VALUES (?, ?, ?, ?, ?, ?)
                       ON CONFLICT(device_id) DO UPDATE SET
                         name=excluded.name, keystrokes=excluded.keystrokes,
                         clicks=excluded.clicks, since=excluded.since,
                         updated_at=excluded.updated_at""",
                    (device_id, name, keystrokes, clicks, since, now))
                conn.executemany(
                    """INSERT INTO days (device_id, date, keystrokes, clicks,
                                         key_frequency, app_frequency, updated_at)
                       VALUES (?, ?, ?, ?, ?, ?, ?)
                       ON CONFLICT(device_id, date) DO UPDATE SET
                         keystrokes=excluded.keystrokes, clicks=excluded.clicks,
                         key_frequency=excluded.key_frequency,
                         app_frequency=excluded.app_frequency,
                         updated_at=excluded.updated_at""",
                    [(device_id, date, k, c, json.dumps(kf), json.dumps(af), now)
                     for date, k, c, kf, af in days])

            others = conn.execute(
                "SELECT name, keystrokes, clicks, since FROM devices WHERE device_id != ?",
                (device_id,)).fetchall()
            rows = conn.execute(
                """SELECT date, keystrokes, clicks, key_frequency, app_frequency
                   FROM days WHERE device_id != ?""",
                (device_id,)).fetchall()
        finally:
            conn.close()

    # Sum the other devices' rows per date.
    merged = {}
    for date, k, c, kf, af in rows:
        day = merged.setdefault(date, {"date": date, "keystrokes": 0, "clicks": 0,
                                       "keyFrequency": {}, "appFrequency": {}})
        day["keystrokes"] += k
        day["clicks"] += c
        for target, source in ((day["keyFrequency"], kf), (day["appFrequency"], af)):
            for key, n in json.loads(source).items():
                target[key] = target.get(key, 0) + n

    sinces = [s for _, _, _, s in others if s]
    return {
        "others": {
            "deviceNames": sorted(n for n, _, _, _ in others),
            "lifetime": {
                "keystrokes": sum(k for _, k, _, _ in others),
                "clicks": sum(c for _, _, c, _ in others),
                # ISO-8601 UTC strings sort chronologically.
                "since": min(sinces) if sinces else None,
            },
            "days": sorted(merged.values(), key=lambda d: d["date"]),
        }
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "keystroke-sync"

    def send_json(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authorized(self):
        header = self.headers.get("Authorization", "")
        return bool(TOKEN) and hmac.compare_digest(header.encode(), f"Bearer {TOKEN}".encode())

    def do_GET(self):
        if self.path == "/healthz":
            self.send_json(200, {"ok": True})
        else:
            self.send_json(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/v1/sync":
            return self.send_json(404, {"error": "not found"})
        if not self.authorized():
            return self.send_json(401, {"error": "unauthorized"})
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = -1
        if length <= 0 or length > MAX_BODY:
            return self.send_json(413 if length > MAX_BODY else 400, {"error": "bad body size"})
        try:
            body = json.loads(self.rfile.read(length))
            self.send_json(200, sync(body))
        except (json.JSONDecodeError, UnicodeDecodeError):
            self.send_json(400, {"error": "invalid JSON"})
        except BadRequest as e:
            self.send_json(400, {"error": str(e)})

    def log_message(self, fmt, *args):
        # One line per request to stdout (docker logs); never bodies.
        print(f"{self.address_string()} {fmt % args}", flush=True)


def main():
    if not TOKEN:
        raise SystemExit("SYNC_TOKEN is not set")
    conn = connect()
    conn.executescript(SCHEMA)
    conn.close()
    print(f"keystroke-sync listening on :{PORT}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
