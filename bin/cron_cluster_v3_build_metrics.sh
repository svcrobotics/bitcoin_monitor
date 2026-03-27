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

ts() { date -Is; }

export RAILS_ENV="${RAILS_ENV:-development}"

echo "[cluster_v3_build_metrics] start $(ts)" >> "$LOG"

t0="$(date +%s)"
set +e

bundle exec bin/rails cluster:v3:build_metrics >> "$LOG" 2>&1
RC=$?

set -e
t1="$(date +%s)"
dur="$((t1 - t0))"

if [ "$RC" -eq 0 ]; then
  echo "[cluster_v3_build_metrics] done rc=$RC dur=${dur}s $(ts)" >> "$LOG"
else
  echo "[cluster_v3_build_metrics] FAIL rc=$RC dur=${dur}s $(ts)" >> "$LOG"
fi

exit "$RC"