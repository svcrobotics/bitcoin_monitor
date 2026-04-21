#!/usr/bin/env bash
set -euo pipefail

APP="/home/victor/bitcoin_monitor"
LOG="$APP/log/cron.victor.log"

mkdir -p "$APP/log"
cd "$APP"

export RBENV_ROOT="${RBENV_ROOT:-/home/victor/.rbenv}"
export PATH="$RBENV_ROOT/bin:$RBENV_ROOT/shims:$PATH"
if command -v rbenv >/dev/null 2>&1; then
  eval "$(rbenv init - bash)"
fi

export BUNDLE_GEMFILE="${BUNDLE_GEMFILE:-$APP/Gemfile}"
export RAILS_ENV="${RAILS_ENV:-development}"
export N="${N:-72}"
export WHALE_MIN_BTC="${WHALE_MIN_BTC:-100}"

echo "[$(date '+%F %T')] [whale_scan] start triggered_by=${TRIGGERED_BY:-cron} scheduled_for=${SCHEDULED_FOR:-} N=${N} WHALE_MIN_BTC=${WHALE_MIN_BTC}" >> "$LOG"

if timeout 3600 bundle exec bin/rails whales:scan; then
  echo "[$(date '+%F %T')] [whale_scan] done" >> "$LOG"
else
  rc=$?
  if [ "$rc" -eq 124 ]; then
    echo "[$(date '+%F %T')] [whale_scan] timeout rc=${rc}" >> "$LOG"
  else
    echo "[$(date '+%F %T')] [whale_scan] failed rc=${rc}" >> "$LOG"
  fi
  exit "$rc"
fi >> "$LOG" 2>&1