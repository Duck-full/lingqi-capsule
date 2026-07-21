#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT_ROOT="$ROOT/../../outputs/performance"
ARCH="$(uname -m)"
TARGET="$ARCH-apple-macos13.1"
BIN="$OUT_ROOT/LingqiPerformanceBenchmark-$ARCH"
REPORT="$OUT_ROOT/performance-report-$ARCH.json"

mkdir -p "$OUT_ROOT"

swiftc \
  -O \
  -D PERFORMANCE_BENCHMARK \
  -target "$TARGET" \
  -parse-as-library \
  "$ROOT/Sources/DailyReminderWidget.swift" \
  "$ROOT/Sources/KnowledgeBaseCore.swift" \
  "$ROOT/Performance/PerformanceBenchmark.swift" \
  -o "$BIN" \
  -framework SwiftUI \
  -framework AppKit \
  -framework UserNotifications

/usr/bin/time -l "$BIN" "$REPORT" 2>&1 | tee "$OUT_ROOT/performance-run-$ARCH.txt"

echo "$REPORT"
