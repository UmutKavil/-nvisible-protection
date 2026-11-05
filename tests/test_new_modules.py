import tempfile
import unittest
from pathlib import Path

from scripts.audit_parser import parse_line
from scripts.config_check import validate_config


class NewModuleTests(unittest.TestCase):
    def test_audit_file_event(self):
        record = parse_line(
            'type=PATH msg=audit(1700000000.1:42) item=0 name="/etc/passwd" '
            'key="guardian_file"'
        )
        self.assertEqual(record["event_type"], "HIDS_DOSYA_DEGISIKLIGI")

    def test_config_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            blocklist = Path(directory) / "blocklist.txt"
            blocklist.touch()
            values = {
                "TRUSTED_DHCP_SERVERS": "",
                "PRIMARY_INTERFACE": "eth0",
                "HONEYPOT_ENABLED": "0",
                "AUDITD_ENABLED": "1",
                "CONFIG_BACKUP_ENABLED": "1",
                "DETECTOR_ARP_SPOOF": "1",
                "THREAT_INTEL_BLOCKLIST": str(blocklist),
            }
            self.assertEqual(validate_config(values), [])
