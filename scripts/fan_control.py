#!/usr/bin/env python3
"""Pi fanını sıcaklığa göre kademeli kontrol eder."""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

EVENT_LOG = Path("/opt/guardian/logs/active/events.jsonl")
FAN_STATE = Path("/sys/class/thermal/cooling_device0/cur_state")
TEMP_COMMAND = ("vcgencmd", "measure_temp")
TEMP_PATTERN = re.compile(r"temp=([0-9]+(?:\.[0-9]+)?)")


def find_vcgencmd() -> str | None:
    """vcgencmd yolunu dağıtımın PATH'inden bulur."""
    return shutil.which("vcgencmd")


def read_temperature() -> float:
    """vcgencmd çıktısından santigrat dereceyi okur."""
    result = subprocess.run(TEMP_COMMAND, check=True, capture_output=True, text=True)
    match = TEMP_PATTERN.search(result.stdout)
    if not match:
        raise ValueError(f"Geçersiz sıcaklık çıktısı: {result.stdout!r}")
    return float(match.group(1))


def fan_level(temperature: float) -> int:
    if temperature < 28:
        return 0
    if temperature < 38:
        return 1
    if temperature < 48:
        return 2
    return 3


def write_event(event_type: str, **details: object) -> None:
    """Olayı mevcut JSONL akışına ekler."""
    EVENT_LOG.parent.mkdir(parents=True, exist_ok=True)
    record = {
        "ts": datetime.now(timezone.utc).timestamp(),
        "tip": event_type,
        "detay": details,
        "severity": "orta" if event_type == "FAN_MAX" else "düşük",
        "group_key": "thermal",
    }
    with EVENT_LOG.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")


def set_fan(level: int) -> None:
    """Kernel cooling device durumunu yazar."""
    FAN_STATE.write_text(f"{level}\n", encoding="ascii")


def main() -> int:
    vcgencmd = find_vcgencmd()
    if vcgencmd is None:
        subprocess.run(
            ("logger", "-t", "guardian-fan", "vcgencmd bulunamadı, fan kontrolü devre dışı"),
            check=False,
        )
        return 0
    previous_level: int | None = None
    was_overheat = False
    while True:
        try:
            result = subprocess.run(
                (vcgencmd, "measure_temp"), check=True, capture_output=True, text=True
            )
            match = TEMP_PATTERN.search(result.stdout)
            if not match:
                raise ValueError(f"Geçersiz sıcaklık çıktısı: {result.stdout!r}")
            temperature = float(match.group(1))
            level = fan_level(temperature)
            if level != previous_level:
                set_fan(level)
                previous_level = level
            is_overheat = temperature >= 48
            if is_overheat and not was_overheat:
                write_event("FAN_MAX", sicaklik=temperature)
            was_overheat = is_overheat
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            print(f"Fan kontrolü başarısız: {error}", flush=True)
        time.sleep(5)


if __name__ == "__main__":
    raise SystemExit(main())
