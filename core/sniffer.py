from __future__ import annotations

import argparse
import gc
import logging
import os
import signal
import socket
import threading
import time
from collections import defaultdict, deque
from typing import Any

from scapy.all import IP, TCP, sniff

from config import load_config
from detectors import DetectorEngine
from logger import JsonEventLogger

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
LOGGER = logging.getLogger("guardian")


def notify_systemd(state: str) -> None:
    notify_socket = os.environ.get("NOTIFY_SOCKET")
    if not notify_socket:
        return
    address = notify_socket
    if notify_socket.startswith("@"):
        address = "\0" + notify_socket[1:]
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as client:
            client.connect(address)
            client.sendall(state.encode())
    except OSError:
        LOGGER.debug("systemd watchdog bildirimi gönderilemedi", exc_info=True)


def maintenance_loop(event_logger: JsonEventLogger) -> None:
    # Watchdog sık beslenir; ağır nesne sayımı yalnızca beş dakikada bir loglanır.
    last_report = 0.0
    while True:
        gc.collect()
        now = time.monotonic()
        if now - last_report >= 300:
            event_logger.event("runtime_maintenance", gc_objects=len(gc.get_objects()))
            last_report = now
        notify_systemd("WATCHDOG=1")
        time.sleep(30)


class AnomalyDetector:
    def __init__(self, event_logger: JsonEventLogger, scan_threshold: int, rate_threshold: int, window: int) -> None:
        self.events = event_logger
        self.scan_threshold = scan_threshold
        self.rate_threshold = rate_threshold
        self.window = window
        self.ports_by_source: dict[str, dict[int, float]] = defaultdict(dict)
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
            ports = self.ports_by_source[source]
            expired_ports = [seen_port for seen_port, seen_at in ports.items()
                             if now - seen_at > self.window]
            for expired_port in expired_ports:
                del ports[expired_port]
            ports[port] = now
            self._alert_once("port_scan", source, len(ports) >= self.scan_threshold,
                             source_ip=source, destination_ip=destination,
                             unique_ports=len(ports))
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
    event_logger = JsonEventLogger(config["EVENT_LOG"], config.get("EVENT_DB"))
    stop_event = threading.Event()

    def request_shutdown(signum: int, _frame: Any) -> None:
        LOGGER.info("Kapatma sinyali alındı: %s", signum)
        event_logger.event("guardian_shutdown", signal=signum)
        stop_event.set()

    signal.signal(signal.SIGTERM, request_shutdown)
    signal.signal(signal.SIGINT, request_shutdown)
    threading.Thread(target=maintenance_loop, args=(event_logger,), daemon=True).start()
    detector = AnomalyDetector(
        event_logger,
        int(config.get("PORT_SCAN_THRESHOLD", "20")),
        int(config.get("CONNECTION_RATE_THRESHOLD", "60")),
        int(config.get("WINDOW_SECONDS", "60")),
    )
    detector_engine = DetectorEngine(event_logger, config)
    interface = config.get("INTERFACE", "auto")
    notify_systemd("READY=1")
    while not stop_event.is_set():
        sniff(
            iface=None if interface == "auto" else interface,
            prn=lambda packet: (detector.observe(packet), detector_engine.observe(packet)),
            store=False,
            timeout=5,
        )
    notify_systemd("STOPPING=1")


if __name__ == "__main__":
    main()
