import tempfile
import unittest
from pathlib import Path

import sys
sys.path.insert(0, str(Path(__file__).parents[1] / "core"))
from config import load_config


class ConfigTests(unittest.TestCase):
    def test_loads_comments_and_values(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "guardian.conf"
            path.write_text(
                "# comment\nINTERFACE=eth0\nEVENT_LOG=/tmp/events.jsonl\n"
                "PORT_SCAN_THRESHOLD=20\n",
                encoding="utf-8",
            )
            self.assertEqual(load_config(str(path)), {
                "INTERFACE": "eth0",
                "EVENT_LOG": "/tmp/events.jsonl",
                "PORT_SCAN_THRESHOLD": "20",
            })

    def test_rejects_invalid_threshold(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "guardian.conf"
            path.write_text("INTERFACE=auto\nEVENT_LOG=/tmp/events.jsonl\nWINDOW_SECONDS=0\n", encoding="utf-8")
            with self.assertRaises(ValueError):
                load_config(str(path))


if __name__ == "__main__":
    unittest.main()
