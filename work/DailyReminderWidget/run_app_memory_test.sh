#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT_ROOT="$ROOT/../../outputs/performance"
APP="${APP_PATH:-$ROOT/../../outputs/灵栖胶囊Capsule.app}"
TEMP_HOME="$(mktemp -d /tmp/lingqi-app-test.XXXXXX)"
DATA_DIR="$TEMP_HOME/Library/Application Support/DailyReminderWidget"
SAMPLE_FILE="$OUT_ROOT/app-runtime-samples-$(uname -m).txt"
SUMMARY_FILE="$OUT_ROOT/app-runtime-summary-$(uname -m).txt"

cleanup() {
  if [[ -n "${APP_PID:-}" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  rm -rf "$TEMP_HOME"
}
trap cleanup EXIT

mkdir -p "$OUT_ROOT" "$DATA_DIR/daily-notes"

python3 - "$DATA_DIR" <<'PY'
import json
import os
import sys
import uuid
from datetime import datetime, timedelta, timezone

data_dir = sys.argv[1]
now = datetime.now(timezone.utc).replace(microsecond=0)
day_count = 365
reminder_count = 5000
seed = "今天围绕产品体验、性能优化、交互细节和发布计划进行记录。保持专注，也给自己留一点呼吸。"
note = (seed * (2000 // len(seed) + 1))[:2000]

reminders = []
for index in range(reminder_count):
    date = now - timedelta(days=index % day_count)
    reminders.append({
        "id": str(uuid.uuid4()),
        "title": f"性能测试事项 {index + 1}",
        "notes": "用于 5000 条事项压力测试",
        "date": date.isoformat().replace("+00:00", "Z"),
        "remindAt": date.replace(hour=index % 24, minute=index % 60).isoformat().replace("+00:00", "Z"),
        "frequency": "once",
        "customInterval": 1,
        "isDone": index % 3 == 0,
        "createdAt": date.isoformat().replace("+00:00", "Z"),
    })

with open(os.path.join(data_dir, "reminders.json"), "w", encoding="utf-8") as handle:
    json.dump(reminders, handle, ensure_ascii=False, sort_keys=True)

notes_dir = os.path.join(data_dir, "daily-notes")
legacy_notes = {}
for offset in range(day_count):
    date = (now - timedelta(days=offset)).strftime("%Y-%m-%d")
    legacy_notes[date] = note
    with open(os.path.join(notes_dir, f"{date}.txt"), "w", encoding="utf-8") as handle:
        handle.write(note)

with open(os.path.join(data_dir, "daily-notes.json"), "w", encoding="utf-8") as handle:
    json.dump(legacy_notes, handle, ensure_ascii=False, sort_keys=True)
PY

if [[ ! -x "$APP/Contents/MacOS/DailyReminderWidget" ]] && [[ -z "${APP_PATH:-}" ]]; then
  "$ROOT/build.sh" >/dev/null
fi

: > "$SAMPLE_FILE"
CFFIXED_USER_HOME="$TEMP_HOME" HOME="$TEMP_HOME" \
  "$APP/Contents/MacOS/DailyReminderWidget" >/dev/null 2>&1 &
APP_PID=$!

for second in $(seq 1 20); do
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "App exited before sampling completed" >&2
    exit 1
  fi
  read -r rss cpu <<<"$(ps -o rss= -o %cpu= -p "$APP_PID")"
  printf "%s\t%s\t%s\n" "$second" "$rss" "$cpu" >> "$SAMPLE_FILE"
  sleep 1
done

awk '
  BEGIN { max_rss=0; sum_cpu=0; idle_cpu=0; idle_count=0 }
  {
    if ($2 > max_rss) max_rss=$2
    sum_cpu += $3
    if ($1 > 10) {
      idle_cpu += $3
      idle_count += 1
    }
  }
  END {
    printf "max_rss_mb=%.2f\n", max_rss/1024
    printf "average_cpu_percent=%.2f\n", sum_cpu/NR
    printf "idle_cpu_percent=%.2f\n", idle_count ? idle_cpu/idle_count : 0
  }
' "$SAMPLE_FILE" | tee "$SUMMARY_FILE"

if [[ -f "$DATA_DIR/performance.log" ]]; then
  cp "$DATA_DIR/performance.log" "$OUT_ROOT/app-performance-log-$(uname -m).txt"
fi

echo "$SUMMARY_FILE"
