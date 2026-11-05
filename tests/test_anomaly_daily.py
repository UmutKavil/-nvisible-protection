import json
import sqlite3
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

from scripts.anomaly_daily import analyse


class AnomalyDailyTests(unittest.TestCase):
    def test_detects_new_type_and_daily_spike(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            database = root / "events.db"
            with sqlite3.connect(database) as connection:
                connection.execute(
                    "CREATE TABLE events (timestamp TEXT, event_type TEXT)"
                )
                for day in range(1, 8):
                    connection.execute(
                        "INSERT INTO events VALUES (?, ?)",
                        (f"2026-01-{day:02d}T12:00:00+00:00", "normal"),
                    )
                for _ in range(4):
                    connection.execute(
                        "INSERT INTO events VALUES (?, ?)",
                        ("2026-01-08T12:00:00+00:00", "normal"),
                    )
                connection.execute(
                    "INSERT INTO events VALUES (?, ?)",
                    ("2026-01-08T12:00:00+00:00", "new_type"),
                )
            report = analyse(
                database,
                root / "events.jsonl",
                root / "reports",
                datetime(2026, 1, 8, 12, tzinfo=timezone.utc),
            )
            self.assertTrue(any(item.get("new_event_type") == "new_type" for item in report["anomalies"]))
            self.assertIn("ANOMALI_GUNLUK", (root / "events.jsonl").read_text())
            self.assertTrue(json.loads((root / "reports/2026-01-08.json").read_text()))
