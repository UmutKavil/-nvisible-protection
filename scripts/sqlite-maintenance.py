from __future__ import annotations

import sqlite3
from datetime import datetime, timedelta, timezone
from pathlib import Path

DATABASE = Path("/opt/guardian/data/events.db")
ARCHIVE_DIR = Path("/opt/guardian/logs/archive")


def main() -> None:
    # Veritabanı yoksa bakım servisi diğer servisleri etkilemeden çıkar.
    if not DATABASE.exists():
        return
    ARCHIVE_DIR.mkdir(parents=True, exist_ok=True)
    cutoff = (datetime.now(timezone.utc) - timedelta(days=183)).isoformat()
    archive = ARCHIVE_DIR / f"events-{datetime.now(timezone.utc):%Y-%m}.db"
    with sqlite3.connect(DATABASE) as db:
        db.execute("PRAGMA journal_mode=WAL")
        db.execute("PRAGMA busy_timeout=10000")
        db.execute("ATTACH DATABASE ? AS archive", (str(archive),))
        db.execute("CREATE TABLE IF NOT EXISTS archive.events AS SELECT * FROM main.events WHERE 0")
        db.execute("INSERT INTO archive.events SELECT * FROM main.events WHERE timestamp < ?", (cutoff,))
        db.execute("DELETE FROM main.events WHERE timestamp < ?", (cutoff,))
        db.commit()
        db.execute("DETACH DATABASE archive")
        db.execute("VACUUM")


if __name__ == "__main__":
    main()
