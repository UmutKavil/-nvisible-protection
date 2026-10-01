from __future__ import annotations

import argparse
import json
import time
from collections import Counter
from pathlib import Path

from rich.console import Console
from rich.live import Live
from rich.table import Table


def render(path: Path) -> Table:
    counts: Counter[str] = Counter()
    total = 0
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines()[-500:]:
            try:
                counts[json.loads(line).get("event_type", "unknown")] += 1
                total += 1
            except json.JSONDecodeError:
                continue
    table = Table(title="Invisible Protection")
    table.add_column("Olay")
    table.add_column("Adet", justify="right")
    for event_type, count in counts.most_common():
        table.add_row(event_type, str(count))
    table.add_row("Toplam", str(total))
    return table


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", default="/opt/guardian/logs/active/events.jsonl")
    args = parser.parse_args()
    console = Console()
    with Live(render(Path(args.log)), console=console, refresh_per_second=2) as live:
        while True:
            time.sleep(0.5)
            live.update(render(Path(args.log)))


if __name__ == "__main__":
    main()
