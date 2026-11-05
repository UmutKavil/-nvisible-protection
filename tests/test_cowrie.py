import json
import tempfile
import unittest
from pathlib import Path

from scripts.cowrie_log_parser import parse_line


class CowrieTests(unittest.TestCase):
    def test_maps_login_and_preserves_payload(self):
        record = parse_line(json.dumps({
            "eventid": "cowrie.login.failed",
            "timestamp": "2026-01-01T00:00:00Z",
            "src_ip": "192.0.2.10",
            "username": "root",
        }))
        self.assertEqual(record["event_type"], "HONEYPOT_BASARISIZ_GIRIS")
        self.assertEqual(record["cowrie_event"]["src_ip"], "192.0.2.10")

    def test_rejects_invalid_json(self):
        self.assertIsNone(parse_line("not-json"))
