from __future__ import annotations

import json
import logging
import os
import sqlite3
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


class JsonEventLogger:
    MAX_BYTES = 100 * 1024 * 1024

    def __init__(self, path: str, database: str | None = None) -> None:
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._logger = logging.getLogger("guardian.events")
        self.database = Path(database) if database else None
        self._database_lock = threading.Lock()
        if self.database:
            try:
                self.database.parent.mkdir(parents=True, exist_ok=True)
                with sqlite3.connect(self.database) as db:
                    db.execute("PRAGMA journal_mode=WAL")
                    db.execute(
                        "CREATE TABLE IF NOT EXISTS events "
                        "(timestamp TEXT NOT NULL, event_type TEXT NOT NULL, payload TEXT NOT NULL)"
                    )
                    db.commit()
            except (OSError, sqlite3.Error):
                self._logger.exception("SQLite olay deposu başlatılamadı: %s", self.database)
                self.database = None

    def event(self, event_type: str, **fields: Any) -> None:
        record = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "event_type": event_type,
            **fields,
        }
        try:
            if self.path.exists() and self.path.stat().st_size >= self.MAX_BYTES:
                rotated = self.path.with_suffix(self.path.suffix + ".1")
                os.replace(self.path, rotated)
            with self.path.open("a", encoding="utf-8") as stream:
                stream.write(json.dumps(record, separators=(",", ":"), sort_keys=True) + "\n")
            if self.database:
                try:
                    with self._database_lock, sqlite3.connect(self.database) as db:
                        db.execute("PRAGMA busy_timeout=10000")
                        db.execute(
                            "INSERT INTO events(timestamp, event_type, payload) VALUES (?, ?, ?)",
                            (record["timestamp"], event_type, json.dumps(record, sort_keys=True)),
                        )
                        db.commit()
                except sqlite3.Error:
                    self._logger.exception("SQLite olay yazımı başarısız: %s", self.database)
        except OSError:
            self._logger.exception("Olay logu yazılamadı: %s", self.path)
