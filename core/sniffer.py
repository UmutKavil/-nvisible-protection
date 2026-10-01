from __future__ import annotations

import argparse
import logging
import time
from collections import defaultdict, deque
from typing import Any

from scapy.all import IP, TCP, sniff

from config import load_config
from logger import JsonEventLogger

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
LOGGER = logging.getLogger("guardian")


class AnomalyDetector:
    def __init__(self, event_logger: JsonEventLogger, scan_threshold: int, rate_threshold: int, window: int) -> None:
        self.events = event_logger
        self.scan_threshold = scan_threshold
        self.rate_threshold = rate_threshold
        self.window = window
        self.ports_by_source: dict[str, set[int]] = defaultdict(set)
        self.recent_connections: deque[tuple[float, str]] = deque()
        self.last_alert: dict[tuple[str, str], float] = {}

    def observe(self, packet: Any) -> None:
        if not packet.haslayer(IP):
            return
        source = packet[IP].src
        destination = packet[IP].dst
        now = time.monotonic()
        self.recent_connections.append((now, source))
        while self.recent_connections and now - self.recent_connections[0][0] > self.window:
            self.recent_connections.popleft()
        if packet.haslayer(TCP):
            port = int(packet[TCP].dport)
            self.ports_by_source[source].add(port)
            self._alert_once("port_scan", source, len(self.ports_by_source[source]) >= self.scan_threshold,
                             source_ip=source, destination_ip=destination,
                             unique_ports=len(self.ports_by_source[source]))
        rate = sum(item_source == source for _, item_source in self.recent_connections)
        self._alert_once("connection_rate", source, rate >= self.rate_threshold,
                         source_ip=source, connections=rate, window_seconds=self.window)

    def _alert_once(self, event_type: str, source: str, condition: bool, **fields: Any) -> None:
        if not condition:
            return
        now = time.monotonic()
        key = (event_type, source)
        if now - self.last_alert.get(key, 0) < self.window:
            return
        self.last_alert[key] = now
        self.events.event(event_type, **fields)
        LOGGER.warning("%s: %s", event_type, fields)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default="/etc/invisible-protection/guardian.conf")
    args = parser.parse_args()
    config = load_config(args.config)
    detector = AnomalyDetector(
        JsonEventLogger(config["EVENT_LOG"]),
        int(config.get("PORT_SCAN_THRESHOLD", "20")),
        int(config.get("CONNECTION_RATE_THRESHOLD", "60")),
        int(config.get("WINDOW_SECONDS", "60")),
    )
    interface = config.get("INTERFACE", "auto")
    sniff(iface=None if interface == "auto" else interface, prn=detector.observe, store=False)


if __name__ == "__main__":
    main()
