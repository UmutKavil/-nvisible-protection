#!/usr/bin/env python3
"""audit.log satırlarını Guardian JSONL olaylarına dönüştürür."""

from __future__ import annotations

import argparse
import json
import re
import time
from datetime import datetime, timezone
from pathlib import Path


AUDIT_HEADER = re.compile(r'msg=audit\((?P<epoch>\d+(?:\.\d+)?):(?P<serial>\d+)\)')
FIELD = re.compile(r'(?P<key>[A-Za-z_]+)=(?P<value>"[^"]*"|\S+)')


def parse_line(line: str) -> dict[str, object] | None:
    """Tek audit satırını anlamlı bir olay varsa döndürür."""
    header = AUDIT_HEADER.search(line)
    if not header:
        return None
    fields = {match.group("key"): match.group("value").strip('"') for match in FIELD.finditer(line)}
    key = fields.get("key", "")
    record_type = fields.get("type", "")
    interesting = (
        "guardian_" in key
        or record_type in {"SYSCALL", "PATH"}
        or fields.get("comm") in {"sudo", "su", "pkexec"}
    )
    if not interesting:
        return None
    timestamp = datetime.fromtimestamp(float(header.group("epoch")), tz=timezone.utc).isoformat()
    event_type = {
        "guardian_file": "HIDS_DOSYA_DEGISIKLIGI",
        "guardian-root-exec": "HIDS_ROOT_EXEC",
        "guardian_privilege": "HIDS_YETKI_YUKSELTME",
    }
    selected_key = next((name for name in event_type if name in key), "")
    if fields.get("comm") in {"sudo", "su", "pkexec"}:
        selected_key = "guardian_privilege"
    return {
        "timestamp": timestamp,
        "event_type": event_type.get(selected_key, "HIDS_AUDIT"),
        "source": "auditd",
        "audit_serial": header.group("serial"),
        "audit_record_type": record_type,
        "audit_key": key,
        "fields": fields,
    }


def append_record(path: Path, record: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")


def follow(audit_path: Path, event_path: Path, start_at_end: bool = True) -> None:
    """Audit logu döndürülse bile inode değişimini algılayarak takip eder."""
    position = audit_path.stat().st_size if start_at_end and audit_path.exists() else 0
    inode: int | None = audit_path.stat().st_ino if audit_path.exists() else None
    while True:
        try:
            current_inode = audit_path.stat().st_ino
            if inode != current_inode:
                inode, position = current_inode, 0
            with audit_path.open("r", encoding="utf-8", errors="replace") as stream:
                stream.seek(position)
                for line in stream:
                    position = stream.tell()
                    record = parse_line(line)
                    if record:
                        append_record(event_path, record)
        except FileNotFoundError:
            pass
        time.sleep(1)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--audit-log", type=Path, default=Path("/var/log/audit/audit.log"))
    parser.add_argument("--event-log", type=Path, default=Path("/opt/guardian/logs/active/events.jsonl"))
    parser.add_argument("--once", action="store_true", help="Mevcut içeriği bir kez işler")
    args = parser.parse_args()
    if args.once:
        if args.audit_log.exists():
            for line in args.audit_log.read_text(encoding="utf-8", errors="replace").splitlines():
                record = parse_line(line)
                if record:
                    append_record(args.event_log, record)
        return 0
    follow(args.audit_log, args.event_log)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
