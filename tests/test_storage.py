import tempfile
import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).parents[1] / "storage"))
from repository import EventRepository


class StorageTests(unittest.TestCase):
    def test_event_query_stats_and_csv(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repository = EventRepository(str(Path(directory) / "events.db"))
            repository.add({
                "timestamp": "2026-01-01T00:00:00+00:00",
                "event_type": "arp_spoofing",
                "severity": "high",
                "source_ip": "192.0.2.1",
            })
            self.assertEqual(repository.stats()["by_severity"]["high"], 1)
            self.assertEqual(repository.list_events()[0]["event_type"], "arp_spoofing")
            self.assertIn("event_type", repository.csv_export())
