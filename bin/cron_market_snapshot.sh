#!/usr/bin/env bash
set -euo pipefail

APP="/home/victor/bitcoin_monitor"
LOG="$APP/log/cron.victor.log"

mkdir -p "$APP/log"
cd "$APP"

# rbenv bootstrap
export RBENV_ROOT="${RBENV_ROOT:-/home/victor/.rbenv}"
export PATH="$RBENV_ROOT/bin:$RBENV_ROOT/shims:$PATH"
if command -v rbenv >/dev/null 2>&1; then
  eval "$(rbenv init - bash)"
fi

export RAILS_ENV="${RAILS_ENV:-development}"

echo "[$(date '+%F %T')] [market_snapshot] start triggered_by=${TRIGGERED_BY:-cron} scheduled_for=${SCHEDULED_FOR:-}" >> "$LOG"

if bin/rails market:snapshot; then
  echo "[$(date '+%F %T')] [market_snapshot] done" >> "$LOG"
else
  rc=$?
  echo "[$(date '+%F %T')] [market_snapshot] failed rc=${rc}" >> "$LOG"
  exit "$rc"
fi >> "$LOG" 2>&1