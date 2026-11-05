#!/usr/bin/env python3
"""Guardian yapılandırmasını servis başlamadan önce doğrular."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


REQUIRED_KEYS = ("TRUSTED_DHCP_SERVERS", "PRIMARY_INTERFACE", "HONEYPOT_ENABLED")
BOOLEAN_KEYS = ("HONEYPOT_ENABLED", "AUDITD_ENABLED", "CONFIG_BACKUP_ENABLED", "ANOMALY_ENABLED")
DETECTOR_PREFIX = "DETECTOR_"


def read_config(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
    return values


def validate_config(values: dict[str, str]) -> list[str]:
    errors = [f"Eksik zorunlu anahtar: {key}" for key in REQUIRED_KEYS if key not in values]
    if values.get("HONEYPOT_TYPE", "dionaea") not in {"dionaea", "cowrie"}:
        errors.append("HONEYPOT_TYPE dionaea veya cowrie olmalıdır")
    bool_keys = sorted({key for key in values if key.startswith(DETECTOR_PREFIX)} | set(BOOLEAN_KEYS))
    for key in bool_keys:
        if key in values and values[key] not in {"0", "1"}:
            errors.append(f"{key} 0 veya 1 olmalıdır")
    blocklist = values.get("THREAT_INTEL_BLOCKLIST", "")
    if blocklist and not Path(blocklist).is_file():
        errors.append(f"THREAT_INTEL_BLOCKLIST dosyası bulunamadı: {blocklist}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=Path("/opt/guardian/config/guardian.conf"))
    args = parser.parse_args()
    try:
        errors = validate_config(read_config(args.config))
    except OSError as exc:
        print(f"Config okunamadı: {exc}", file=sys.stderr)
        return 1
    if errors:
        for error in errors:
            print(f"CONFIG HATASI: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
