from __future__ import annotations

import hashlib
import json
import logging
import shutil
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

from logger import JsonEventLogger

LOGGER = logging.getLogger("guardian.system-monitor")


def command_output(command: list[str]) -> str | None:
    try:
        return subprocess.check_output(
            command, text=True, stderr=subprocess.DEVNULL, timeout=5
        ).strip()
    except (OSError, subprocess.SubprocessError):
        return None


def ntp_state() -> str:
    output = command_output(["timedatectl", "show", "-p", "NTPSynchronized", "--value"])
    return output or "unknown"


def kernel_warnings() -> list[str]:
    output = command_output(
        ["journalctl", "--quiet", "--no-pager", "-k", "-p", "warning..alert", "-n", "20"]
    )
    return output.splitlines() if output else []


def monitor(logger: JsonEventLogger, interval: int = 60) -> None:
    seen_kernel: set[str] = set()
    while True:
        usage = shutil.disk_usage("/opt/guardian")
        logger.event(
            "system_status",
            disk_percent=round(100 * (usage.total - usage.free) / usage.total, 2),
            ntp_synchronized=ntp_state(),
        )
        for line in kernel_warnings():
            fingerprint = hashlib.sha256(line.encode("utf-8")).hexdigest()
            if fingerprint not in seen_kernel:
                logger.event("kernel_warning", message=line)
                seen_kernel.add(fingerprint)
        if len(seen_kernel) > 256:
            seen_kernel.clear()
        time.sleep(interval)


def main() -> None:
    logger = JsonEventLogger(
        "/opt/guardian/logs/active/events.jsonl",
        "/opt/guardian/data/events.db",
    )
    monitor(logger)


if __name__ == "__main__":
    main()
