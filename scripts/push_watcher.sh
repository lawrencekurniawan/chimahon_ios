#!/bin/zsh
# Push watcher (strict gate policy): waits for the Gemini quota reset,
# re-runs scripts/run_tests.sh, pushes ONLY if the gate exits 0.
# Logs everything to gate_push_watcher.log. Started by Claude on 2026-10-22.
set -u
cd "$(dirname "$0")/.."
LOG=gate_push_watcher.log

echo "=== watcher started $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$LOG"

# Wait until the observed quota reset (429 said "retry in 6h38m" at ~07:17 → ~13:56)
TARGET_EPOCH=$(date -j -f "%Y-%m-%d %H:%M" "2026-10-22 13:56" +%s 2>/dev/null || echo 0)
if [[ "$TARGET_EPOCH" != "0" ]]; then
  while [ "$(date +%s)" -lt "$TARGET_EPOCH" ]; do sleep 60; done
fi
echo "=== quota window passed, starting gate attempts $(date '+%H:%M:%S') ===" >> "$LOG"

for i in 1 2 3 4 5 6 7 8; do
  echo "--- gate attempt $i at $(date '+%H:%M:%S') ---" >> "$LOG"
  if ./scripts/run_tests.sh >> "$LOG" 2>&1; then
    echo "--- gate GREEN at $(date '+%H:%M:%S'), pushing ---" >> "$LOG"
    if git push >> "$LOG" 2>&1; then
      echo "PUSHED OK: $(git log --oneline -1) at $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG"
      exit 0
    fi
    echo "PUSH FAILED (remote issue) at $(date '+%H:%M:%S')" >> "$LOG"
    exit 2
  fi
  echo "--- gate still red, sleeping 10 min ---" >> "$LOG"
  sleep 600
done

echo "GAVE UP after 8 attempts at $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG"
exit 1
