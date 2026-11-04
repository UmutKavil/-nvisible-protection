from __future__ import annotations

import time
from collections import defaultdict, deque
from typing import Any, Protocol

from scapy.layers.dhcp import DHCP, BOOTP
from scapy.layers.dns import DNS, DNSQR
from scapy.layers.inet import ICMP, IP, TCP
from scapy.layers.l2 import ARP, Ether


class EventSink(Protocol):
    def event(self, event_type: str, **fields: Any) -> None: ...


def enabled(config: dict[str, str], name: str, default: bool = False) -> bool:
    value = config.get(f"DETECTOR_{name.upper()}", "1" if default else "0")
    return value.strip().lower() in {"1", "true", "yes", "on"}


class Detector(Protocol):
    name: str

    def observe(self, packet: Any, now: float) -> None: ...


class AlertLimiter:
    def __init__(self, window: int) -> None:
        self.window = window
        self.last: dict[tuple[str, str], float] = {}

    def allow(self, event_type: str, key: str, now: float) -> bool:
        marker = (event_type, key)
        if now - self.last.get(marker, 0) < self.window:
            return False
        self.last[marker] = now
        return True


class ArpSpoofDetector:
    name = "arp_spoof"

    def __init__(self, events: EventSink, window: int) -> None:
        self.events = events
        self.known: dict[str, str] = {}
        self.limiter = AlertLimiter(window)

    def observe(self, packet: Any, now: float) -> None:
        if not packet.haslayer(ARP):
            return
        arp = packet[ARP]
        if int(arp.op) not in (1, 2) or not arp.psrc or not arp.hwsrc:
            return
        previous = self.known.get(arp.psrc)
        self.known[arp.psrc] = arp.hwsrc.lower()
        if previous and previous != arp.hwsrc.lower() and self.limiter.allow(
            self.name, arp.psrc, now
        ):
            self.events.event(
                "arp_spoofing",
                severity="high",
                ip=arp.psrc,
                previous_mac=previous,
                current_mac=arp.hwsrc.lower(),
            )


class RogueDhcpDetector:
    name = "rogue_dhcp"

    def __init__(self, events: EventSink, trusted_servers: set[str], window: int) -> None:
        self.events = events
        self.trusted_servers = trusted_servers
        self.limiter = AlertLimiter(window)

    def observe(self, packet: Any, now: float) -> None:
        if not packet.haslayer(DHCP) or not packet.haslayer(BOOTP):
            return
        options = {
            option[0]: option[1]
            for option in packet[DHCP].options
            if isinstance(option, tuple) and len(option) > 1
        }
        if options.get("message-type") not in (2, 5):
            return
        server = options.get("server_id") or packet[BOOTP].yiaddr
        if isinstance(server, bytes):
            server = server.decode(errors="replace")
        server = str(server)
        if self.trusted_servers and server not in self.trusted_servers and self.limiter.allow(
            self.name, server, now
        ):
            self.events.event("rogue_dhcp", severity="high", server_ip=server)


class DnsAnomalyDetector:
    name = "dns_anomaly"

    def __init__(self, events: EventSink, window: int, max_name_length: int) -> None:
        self.events = events
        self.max_name_length = max_name_length
        self.answers: dict[str, set[str]] = defaultdict(set)
        self.limiter = AlertLimiter(window)

    @staticmethod
    def _text(value: Any) -> str:
        return value.decode(errors="replace").rstrip(".") if isinstance(value, bytes) else str(value)

    def observe(self, packet: Any, now: float) -> None:
        if not packet.haslayer(DNS) or not packet.haslayer(DNSQR):
            return
        query = self._text(packet[DNSQR].qname)
        labels = query.split(".")
        longest = max((len(label) for label in labels), default=0)
        if (len(query) >= self.max_name_length or longest >= 45) and self.limiter.allow(
            "dns_tunneling", query, now
        ):
            self.events.event(
                "dns_tunneling_indicator",
                severity="medium",
                query=query,
                query_length=len(query),
                longest_label=longest,
            )
        if int(packet[DNS].qr) != 1:
            return
        answers = packet[DNS].an
        for index in range(int(packet[DNS].ancount or 0)):
            record = answers[index]
            if getattr(record, "type", None) in (1, 28):
                address = self._text(record.rdata)
                seen = self.answers[query]
                if seen and address not in seen and self.limiter.allow("dns_spoofing", query, now):
                    self.events.event(
                        "dns_response_conflict",
                        severity="medium",
                        query=query,
                        previous_answers=sorted(seen),
                        new_answer=address,
                    )
                seen.add(address)


class IcmpTunnelDetector:
    name = "icmp_tunnel"

    def __init__(self, events: EventSink, window: int, payload_limit: int, rate_limit: int) -> None:
        self.events = events
        self.window = window
        self.payload_limit = payload_limit
        self.rate_limit = rate_limit
        self.recent: deque[tuple[float, str]] = deque()
        self.limiter = AlertLimiter(window)

    def observe(self, packet: Any, now: float) -> None:
        if not packet.haslayer(ICMP) or not packet.haslayer(IP):
            return
        payload = bytes(packet[ICMP].payload)
        source = packet[IP].src
        if len(payload) < self.payload_limit:
            return
        self.recent.append((now, source))
        while self.recent and now - self.recent[0][0] > self.window:
            self.recent.popleft()
        count = sum(item_source == source for _, item_source in self.recent)
        if count >= self.rate_limit and self.limiter.allow(self.name, source, now):
            self.events.event(
                "icmp_tunneling_indicator",
                severity="medium",
                source_ip=source,
                payload_bytes=len(payload),
                packets=count,
            )


class SlowPortScanDetector:
    name = "slow_port_scan"

    def __init__(self, events: EventSink, window: int, threshold: int) -> None:
        self.events = events
        self.window = window
        self.threshold = threshold
        self.ports: dict[str, dict[int, float]] = defaultdict(dict)
        self.limiter = AlertLimiter(window)

    def observe(self, packet: Any, now: float) -> None:
        if not packet.haslayer(IP) or not packet.haslayer(TCP):
            return
        source = packet[IP].src
        ports = self.ports[source]
        for port, seen_at in list(ports.items()):
            if now - seen_at > self.window:
                del ports[port]
        ports[int(packet[TCP].dport)] = now
        if len(ports) >= self.threshold and self.limiter.allow(self.name, source, now):
            self.events.event(
                "slow_port_scan",
                severity="medium",
                source_ip=source,
                unique_ports=len(ports),
                window_seconds=self.window,
            )


class DeviceDetector:
    name = "new_device"

    def __init__(self, events: EventSink, window: int) -> None:
        self.events = events
        self.seen: set[str] = set()
        self.limiter = AlertLimiter(window)

    def observe(self, packet: Any, now: float) -> None:
        if not packet.haslayer(Ether):
            return
        mac = str(packet[Ether].src).lower()
        if not mac or mac in self.seen:
            return
        self.seen.add(mac)
        if self.limiter.allow(self.name, mac, now):
            self.events.event("new_device", severity="low", source_mac=mac)


class MacFloodDetector:
    name = "mac_flooding"

    def __init__(self, events: EventSink, window: int, threshold: int) -> None:
        self.events = events
        self.window = window
        self.threshold = threshold
        self.recent: deque[tuple[float, str]] = deque()
        self.limiter = AlertLimiter(window)

    def observe(self, packet: Any, now: float) -> None:
        if not packet.haslayer(Ether):
            return
        self.recent.append((now, str(packet[Ether].src).lower()))
        while self.recent and now - self.recent[0][0] > self.window:
            self.recent.popleft()
        unique = {mac for _, mac in self.recent}
        if len(unique) >= self.threshold and self.limiter.allow(self.name, "global", now):
            self.events.event(
                "mac_flooding_indicator",
                severity="high",
                unique_source_macs=len(unique),
                window_seconds=self.window,
            )


class ThreatIntelDetector:
    name = "threat_intel"

    def __init__(self, events: EventSink, blocklist_path: str, window: int) -> None:
        self.events = events
        self.blocklist = self._load(blocklist_path)
        self.limiter = AlertLimiter(window)

    @staticmethod
    def _load(path: str) -> set[str]:
        try:
            with open(path, encoding="utf-8") as stream:
                return {
                    line.strip()
                    for line in stream
                    if line.strip() and not line.startswith("#")
                }
        except OSError:
            return set()

    def observe(self, packet: Any, now: float) -> None:
        if not packet.haslayer(IP):
            return
        for address in (packet[IP].src, packet[IP].dst):
            if address in self.blocklist and self.limiter.allow(self.name, address, now):
                self.events.event(
                    "threat_intel_match",
                    severity="high",
                    ip=address,
                    blocklist="configured",
                )


class DetectorEngine:
    def __init__(self, events: EventSink, config: dict[str, str]) -> None:
        self.events = events
        window = int(config.get("WINDOW_SECONDS", "60"))
        trusted = {
            value.strip()
            for value in config.get("TRUSTED_DHCP_SERVERS", "").split(",")
            if value.strip()
        }
        self.detectors: list[Detector] = []
        candidates: list[tuple[str, Detector]] = [
            ("arp_spoof", ArpSpoofDetector(events, window)),
            ("rogue_dhcp", RogueDhcpDetector(events, trusted, window)),
            ("dns", DnsAnomalyDetector(events, window, int(config.get("DNS_MAX_NAME_LENGTH", "80")))),
            ("icmp", IcmpTunnelDetector(events, window, int(config.get("ICMP_PAYLOAD_LIMIT", "256")),
                                         int(config.get("ICMP_RATE_LIMIT", "10")))),
            ("slow_port_scan", SlowPortScanDetector(
                events, max(window, int(config.get("SLOW_SCAN_WINDOW_SECONDS", "900"))),
                int(config.get("SLOW_SCAN_THRESHOLD", "20")),
            )),
            ("new_device", DeviceDetector(events, window)),
            ("mac_flooding", MacFloodDetector(
                events, window, int(config.get("MAC_FLOOD_THRESHOLD", "200")),
            )),
            ("threat_intel", ThreatIntelDetector(
                events, config.get("THREAT_INTEL_BLOCKLIST", "/opt/guardian/config/blocklist.txt"), window,
            )),
        ]
        for name, detector in candidates:
            if enabled(config, name):
                self.detectors.append(detector)

    def observe(self, packet: Any) -> None:
        now = time.monotonic()
        for detector in self.detectors:
            try:
                detector.observe(packet, now)
            except (AttributeError, IndexError, KeyError, TypeError, ValueError) as exc:
                self.detectors.remove(detector)
                # Detector hatası çekirdek sniff döngüsünü durdurmaz.
                self.events.event("detector_error", detector=detector.name, error=type(exc).__name__)
