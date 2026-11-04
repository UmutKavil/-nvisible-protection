import tempfile
import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).parents[1] / "core"))
try:
    from scapy.layers.inet import IP
    from scapy.layers.l2 import ARP, Ether
    from detectors import ArpSpoofDetector, DetectorEngine, ThreatIntelDetector
except ModuleNotFoundError as error:
    IP = ARP = Ether = None
    ArpSpoofDetector = DetectorEngine = ThreatIntelDetector = None
    SCAPY_IMPORT_ERROR = error
else:
    SCAPY_IMPORT_ERROR = None


class EventSink:
    def __init__(self) -> None:
        self.events = []

    def event(self, event_type: str, **fields: object) -> None:
        self.events.append((event_type, fields))


@unittest.skipIf(SCAPY_IMPORT_ERROR is not None, "Scapy is not installed")
class DetectorTests(unittest.TestCase):
    def test_arp_mac_change_is_reported(self) -> None:
        sink = EventSink()
        detector = ArpSpoofDetector(sink, window=60)
        detector.observe(ARP(psrc="192.0.2.1", hwsrc="00:11:22:33:44:55"), 1)
        detector.observe(ARP(psrc="192.0.2.1", hwsrc="66:77:88:99:aa:bb"), 2)
        self.assertEqual(sink.events[0][0], "arp_spoofing")

    def test_threat_intel_matches_ip(self) -> None:
        sink = EventSink()
        with tempfile.TemporaryDirectory() as directory:
            blocklist = Path(directory) / "blocklist.txt"
            blocklist.write_text("198.51.100.10\n", encoding="utf-8")
            detector = ThreatIntelDetector(sink, str(blocklist), window=60)
            detector.observe(Ether() / IP(dst="198.51.100.10"), 1)
        self.assertEqual(sink.events[0][0], "threat_intel_match")

    def test_engine_respects_detector_switches(self) -> None:
        sink = EventSink()
        engine = DetectorEngine(sink, {
            "WINDOW_SECONDS": "60",
            "DETECTOR_ARP_SPOOF": "1",
            "DETECTOR_DNS": "0",
        })
        names = {detector.name for detector in engine.detectors}
        self.assertIn("arp_spoof", names)
        self.assertNotIn("dns", names)


if __name__ == "__main__":
    unittest.main()
