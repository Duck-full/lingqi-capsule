#!/usr/bin/env python3
"""Export existing Lingqi Capsule macOS data into the iOS migration format."""

from __future__ import annotations

import argparse
import datetime as dt
import json
from pathlib import Path


DEFAULT_SOURCE = Path.home() / "Library/Application Support/DailyReminderWidget"


def load_notes(source: Path) -> list[dict[str, str]]:
    notes_dir = source / "daily-notes"
    notes: list[dict[str, str]] = []
    if notes_dir.exists():
        for path in sorted(notes_dir.glob("*.txt")):
            text = path.read_text(encoding="utf-8").strip()
            if text:
                notes.append({"date": path.stem, "text": text})
        return notes

    legacy = source / "daily-notes.json"
    if legacy.exists():
        data = json.loads(legacy.read_text(encoding="utf-8"))
        return [
            {"date": key, "text": str(value).strip()}
            for key, value in sorted(data.items())
            if str(value).strip()
        ]
    return notes


def load_reminders(source: Path) -> list[dict]:
    path = source / "reminders.json"
    if not path.exists():
        return []
    reminders = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(reminders, list):
        raise ValueError("reminders.json must contain a JSON array")
    return reminders


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    package = {
        "version": 1,
        "exportedAt": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
        "notes": load_notes(args.source),
        "reminders": load_reminders(args.source),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(package, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(
        f"Exported {len(package['notes'])} notes and "
        f"{len(package['reminders'])} reminders to {args.output}"
    )


if __name__ == "__main__":
    main()
