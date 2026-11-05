#!/usr/bin/env python3
"""Günlük olay istatistiklerini çıkarır ve anormallikleri JSONL'e yazar."""

from __future__ import annotations

import argparse
import json
import sqlite3
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

import pandas as pd


def load_events(database: Path, start: datetime, end: datetime) -> pd.DataFrame:
    """SQLite olaylarını zaman aralığında Pandas DataFrame olarak okur."""
    with sqlite3.connect(database) as connection:
        rows = connection.execute(
            "SELECT timestamp, event_type FROM events "
            "WHERE timestamp >= ? AND timestamp < ?",
            (start.isoformat(), end.isoformat()),
        ).fetchall()
    frame = pd.DataFrame(rows, columns=["timestamp", "event_type"])
    if frame.empty:
        frame["timestamp"] = pd.to_datetime(frame["timestamp"], utc=True)
        return frame
    frame["timestamp"] = pd.to_datetime(frame["timestamp"], utc=True, errors="coerce")
    return frame.dropna(subset=["timestamp", "event_type"])


def append_event(path: Path, event_name: str, **fields: Any) -> None:
    """Anomali olayını mevcut JSONL akışına ekler."""
    path.parent.mkdir(parents=True, exist_ok=True)
    record = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "event_type": event_name,
        "source": "anomaly_daily",
        **fields,
    }
    with path.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")


def analyse(
    database: Path,
    event_log: Path,
    report_dir: Path,
    now: datetime | None = None,
    threshold: float = 3.0,
    write_events: bool = True,
) -> dict[str, Any]:
    """Son günü önceki yedi günlük baseline ile karşılaştırır."""
    current = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    today_start = current.replace(hour=0, minute=0, second=0, microsecond=0)
    tomorrow = today_start + timedelta(days=1)
    baseline_start = today_start - timedelta(days=7)
    today = load_events(database, today_start, tomorrow)
    baseline = load_events(database, baseline_start, today_start)

    today_counts = today["event_type"].value_counts()
    baseline_counts = baseline.groupby(
        [baseline["timestamp"].dt.date, "event_type"]
    ).size().unstack(fill_value=0)
    all_types = sorted(set(today_counts.index) | set(baseline_counts.columns))
    anomalies: list[dict[str, Any]] = []
    daily_stats: dict[str, dict[str, float]] = {}
    for event_type in all_types:
        count = int(today_counts.get(event_type, 0))
        mean = float(baseline_counts[event_type].mean()) if event_type in baseline_counts else 0.0
        daily_stats[event_type] = {"today": count, "baseline_average": round(mean, 3)}
        if count > 0 and (mean == 0 or count >= mean * threshold):
            item = {
                "observed_event_type": event_type,
                "today": count,
                "baseline_average": round(mean, 3),
            }
            anomalies.append(item)
            if write_events:
                append_event(event_log, "ANOMALI_GUNLUK", **item)

    baseline_types = set(baseline["event_type"].unique())
    for event_type in sorted(set(today["event_type"].unique()) - baseline_types):
        item = {"event_type": event_type}
        anomalies.append({"new_event_type": event_type})
        if write_events:
            append_event(event_log, "YENI_OLAY_TIPI", **item)

    today_night = int(today[today["timestamp"].dt.hour.isin([2, 3, 4])].shape[0])
    baseline_night = baseline[baseline["timestamp"].dt.hour.isin([2, 3, 4])]
    night_average = len(baseline_night) / 7
    if today_night > 0 and (night_average == 0 or today_night >= night_average * threshold):
        item = {"today": today_night, "baseline_average": round(night_average, 3)}
        anomalies.append({"night_activity": item})
        if write_events:
            append_event(event_log, "GECE_AKTIVITESI", **item)

    report = {
        "date": today_start.date().isoformat(),
        "period": {"start": today_start.isoformat(), "end": tomorrow.isoformat()},
        "baseline_days": 7,
        "daily_stats": daily_stats,
        "night_activity": {"today": today_night, "baseline_average": round(night_average, 3)},
        "anomalies": anomalies,
    }
    report_dir.mkdir(parents=True, exist_ok=True)
    report_path = report_dir / f"{today_start.date().isoformat()}.json"
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", type=Path, default=Path("/opt/guardian/data/events.db"))
    parser.add_argument("--event-log", type=Path, default=Path("/opt/guardian/logs/active/events.jsonl"))
    parser.add_argument("--report-dir", type=Path, default=Path("/opt/guardian/logs/anomaly"))
    parser.add_argument("--config", type=Path, default=Path("/opt/guardian/config/guardian.conf"))
    parser.add_argument("--threshold", type=float, default=3.0)
    parser.add_argument("--dry-run", action="store_true", help="Rapor üretir, olay loguna yazmaz")
    args = parser.parse_args()
    threshold = args.threshold
    if args.threshold == 3.0 and args.config.exists():
        for line in args.config.read_text(encoding="utf-8").splitlines():
            if line.startswith("ANOMALY_THRESHOLD="):
                threshold = float(line.split("=", 1)[1].strip())
                break
    analyse(
        args.database,
        args.event_log,
        args.report_dir,
        threshold=threshold,
        write_events=not args.dry_run,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
