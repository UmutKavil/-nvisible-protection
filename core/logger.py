from __future__ import annotations

import json
import logging
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


class JsonEventLogger:
    MAX_BYTES = 100 * 1024 * 1024

    def __init__(self, path: str) -> None:
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._logger = logging.getLogger("guardian.events")

    def event(self, event_type: str, **fields: Any) -> None:
        record = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "event_type": event_type,
            **fields,
        }
        try:
            if self.path.exists() and self.path.stat().st_size >= self.MAX_BYTES:
                rotated = self.path.with_suffix(self.path.suffix + ".1")
                os.replace(self.path, rotated)
            with self.path.open("a", encoding="utf-8") as stream:
                stream.write(json.dumps(record, separators=(",", ":"), sort_keys=True) + "\n")
        except OSError:
            self._logger.exception("Olay logu yazılamadı: %s", self.path)
