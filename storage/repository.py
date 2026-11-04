from __future__ import annotations

import csv
import io
import json
import sqlite3
from contextlib import contextmanager
from pathlib import Path
from typing import Any


SEVERITIES = {"critical", "high", "medium", "low", "info"}


class EventRepository:
    def __init__(self, path: str) -> None:
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._initialize()

    @contextmanager
    def _connect(self) -> Any:
        db = sqlite3.connect(self.path, timeout=10)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA busy_timeout=10000")
        db.execute("PRAGMA journal_mode=WAL")
        try:
            yield db
        finally:
            db.close()

    def _initialize(self) -> None:
        with self._connect() as db:
            db.execute(
                "CREATE TABLE IF NOT EXISTS events ("
                "id INTEGER PRIMARY KEY AUTOINCREMENT,"
                "timestamp TEXT NOT NULL,"
                "event_type TEXT NOT NULL,"
                "severity TEXT NOT NULL DEFAULT 'info',"
                "group_key TEXT NOT NULL DEFAULT '',"
                "payload TEXT NOT NULL)"
            )
            columns = {row["name"] for row in db.execute("PRAGMA table_info(events)")}
            for name, definition in (
                ("severity", "TEXT NOT NULL DEFAULT 'info'"),
                ("group_key", "TEXT NOT NULL DEFAULT ''"),
            ):
                if name not in columns:
                    db.execute(f"ALTER TABLE events ADD COLUMN {name} {definition}")
            db.execute("CREATE INDEX IF NOT EXISTS idx_events_timestamp ON events(timestamp)")
            db.execute("CREATE INDEX IF NOT EXISTS idx_events_severity ON events(severity)")
            db.commit()

    def add(self, record: dict[str, Any]) -> None:
        severity = str(record.get("severity", "info")).lower()
        if severity not in SEVERITIES:
            severity = "info"
        group_key = f"{record.get('event_type', 'unknown')}:{record.get('source_ip', record.get('ip', ''))}"
        with self._connect() as db:
            db.execute(
                "INSERT INTO events(timestamp,event_type,severity,group_key,payload) VALUES(?,?,?,?,?)",
                (record["timestamp"], record["event_type"], severity, group_key,
                 json.dumps(record, sort_keys=True)),
            )
            db.commit()

    def list_events(self, limit: int = 100, offset: int = 0, severity: str | None = None) -> list[dict[str, Any]]:
        limit = max(1, min(limit, 500))
        query =         "SELECT rowid AS id,timestamp,event_type,severity,group_key,payload FROM events"
        parameters: list[Any] = []
        if severity:
            query += " WHERE severity = ?"
            parameters.append(severity)
        query += " ORDER BY id DESC LIMIT ? OFFSET ?"
        parameters.extend((limit, max(offset, 0)))
        with self._connect() as db:
            rows = db.execute(query, parameters).fetchall()
        result = []
        for row in rows:
            item = json.loads(row["payload"])
            item.update({"id": row["id"], "severity": row["severity"], "group_key": row["group_key"]})
            result.append(item)
        return result

    def stats(self) -> dict[str, Any]:
        with self._connect() as db:
            by_severity = {
                row["severity"]: row["count"]
                for row in db.execute("SELECT severity, COUNT(*) AS count FROM events GROUP BY severity")
            }
            by_type = {
                row["event_type"]: row["count"]
                for row in db.execute("SELECT event_type, COUNT(*) AS count FROM events GROUP BY event_type")
            }
            total = db.execute("SELECT COUNT(*) FROM events").fetchone()[0]
        return {"total": total, "by_severity": by_severity, "by_type": by_type}

    def csv_export(self, limit: int = 5000) -> str:
        rows = self.list_events(limit=limit)
        output = io.StringIO()
        writer = csv.DictWriter(output, fieldnames=("id", "timestamp", "event_type", "severity", "group_key", "payload"))
        writer.writeheader()
        for row in rows:
            writer.writerow({
                "id": row.get("id"),
                "timestamp": row.get("timestamp"),
                "event_type": row.get("event_type"),
                "severity": row.get("severity"),
                "group_key": row.get("group_key"),
                "payload": json.dumps(row, ensure_ascii=False, sort_keys=True),
            })
        return output.getvalue()
