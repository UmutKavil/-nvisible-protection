from __future__ import annotations

import json
import os
import subprocess
from datetime import datetime, timezone
from pathlib import Path

import psutil
from flask import Flask, jsonify

app = Flask(__name__)
EVENT_LOG = Path(os.environ.get("GUARDIAN_EVENT_LOG", "/opt/guardian/logs/active/events.jsonl"))


def cpu_temperature() -> float | None:
    # vcgencmd yalnızca yerel makinede çalışır; endpoint dışarıdan komut kabul etmez.
    try:
        output = subprocess.check_output(
            ["vcgencmd", "measure_temp"], text=True, timeout=2
        )
    except (OSError, subprocess.SubprocessError):
        return None
    try:
        return float(output.split("=")[1].split("'")[0])
    except (IndexError, ValueError):
        return None


def last_event() -> str | None:
    if not EVENT_LOG.exists():
        return None
    try:
        for line in reversed(EVENT_LOG.read_text(encoding="utf-8").splitlines()):
            record = json.loads(line)
            return str(record.get("timestamp"))
    except (OSError, json.JSONDecodeError):
        return None
    return None


def service_status() -> str:
    try:
        return subprocess.check_output(
            ["systemctl", "is-active", "guardian-core.service"],
            text=True,
            stderr=subprocess.DEVNULL,
            timeout=2,
        ).strip()
    except (OSError, subprocess.SubprocessError):
        return "unknown"


@app.get("/health")
def health() -> tuple[object, int]:
    memory = psutil.virtual_memory()
    disk = psutil.disk_usage("/opt/guardian")
    return jsonify({
        "temperature_c": cpu_temperature(),
        "memory_percent": memory.percent,
        "memory_used_bytes": memory.used,
        "last_event": last_event(),
        "guardian_core": service_status(),
        "disk_percent": disk.percent,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }), 200


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8765, threaded=False)
