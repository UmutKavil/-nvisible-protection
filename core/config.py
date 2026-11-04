from __future__ import annotations

from pathlib import Path


REQUIRED_KEYS = ("INTERFACE", "EVENT_LOG")
INTEGER_KEYS = ("PORT_SCAN_THRESHOLD", "CONNECTION_RATE_THRESHOLD", "WINDOW_SECONDS")


def load_config(path: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        result[key.strip()] = value.strip()
    validate_config(result)
    return result


def validate_config(config: dict[str, str]) -> None:
    missing = [key for key in REQUIRED_KEYS if not config.get(key)]
    if missing:
        raise ValueError(f"Missing configuration keys: {', '.join(missing)}")
    for key in INTEGER_KEYS:
        if key in config:
            try:
                value = int(config[key])
            except ValueError as exc:
                raise ValueError(f"{key} must be an integer") from exc
            if value <= 0:
                raise ValueError(f"{key} must be greater than zero")
    event_log = Path(config["EVENT_LOG"])
    if event_log.name in ("", ".", ".."):
        raise ValueError("EVENT_LOG must point to a file")
