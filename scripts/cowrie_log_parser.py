#!/usr/bin/env python3
"""Cowrie JSON olaylarını Guardian JSONL akışına dönüştürür."""

from __future__ import annotations

import argparse
import json
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


EVENT_TYPES = {
    "cowrie.session.connect": "COWRIE_LOGIN",
    "cowrie.login.failed": "COWRIE_LOGIN",
    "cowrie.login.success": "COWRIE_LOGIN",
    "cowrie.command.input": "COWRIE_COMMAND",
    "cowrie.session.file_download": "COWRIE_DOWNLOAD",
}


def parse_line(line: str) -> dict[str, Any] | None:
    """Tek Cowrie JSON satırını Guardian olayına çevirir."""
    try:
        source = json.loads(line)
    except json.JSONDecodeError:
        return None
    if not isinstance(source, dict) or not source.get("eventid"):
        return None
    timestamp = source.get("timestamp")
    if not timestamp:
        timestamp = datetime.now(timezone.utc).isoformat()
    return {
        "timestamp": timestamp,
        "event_type": EVENT_TYPES.get(str(source["eventid"]), "HONEYPOT_ETKILESIMI"),
        "source": "cowrie",
        "cowrie_event": source,
    }


def append_event(path: Path, record: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")


def follow(source_path: Path, event_path: Path) -> None:
    position = 0
    inode: int | None = None
    while True:
        try:
            current_inode = source_path.stat().st_ino
            if inode != current_inode:
                inode, position = current_inode, 0
            with source_path.open("r", encoding="utf-8", errors="replace") as stream:
                stream.seek(position)
                for line in stream:
                    position = stream.tell()
                    record = parse_line(line)
                    if record:
                        append_event(event_path, record)
        except FileNotFoundError:
            pass
        time.sleep(1)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", type=Path, default=Path("/opt/guardian/cowrie/log/cowrie.json"))
    parser.add_argument("--event-log", type=Path, default=Path("/opt/guardian/logs/active/events.jsonl"))
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()
    if args.once:
        if args.log.exists():
            for line in args.log.read_text(encoding="utf-8", errors="replace").splitlines():
                record = parse_line(line)
                if record:
                    append_event(args.event_log, record)
        return 0
    follow(args.log, args.event_log)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
