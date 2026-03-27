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

ts() { date -Is; }

export RAILS_ENV="${RAILS_ENV:-development}"

echo "[cluster_scan] start $(ts)" | tee -a "$LOG"

t0="$(date +%s)"
set +e

bundle exec bin/rails cluster:scan 2>&1 | tee -a "$LOG"
RC=${PIPESTATUS[0]}

t1="$(date +%s)"
dur="$((t1 - t0))"

if [ "$RC" -eq 0 ]; then
  echo "[cluster_scan] done rc=$RC dur=${dur}s $(ts)" | tee -a "$LOG"
else
  echo "[cluster_scan] FAIL rc=$RC dur=${dur}s $(ts)" | tee -a "$LOG"
fi

exit "$RC"
