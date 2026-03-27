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

echo "[inflow_outflow_capital_behavior_build] start $(ts)" >> "$LOG"

t0="$(date +%s)"
set +e

bundle exec bin/rails runner "InflowOutflowCapitalBehaviorBuildJob.perform_now" >> "$LOG" 2>&1
RC=$?

t1="$(date +%s)"
dur="$((t1 - t0))"

if [ "$RC" -eq 0 ]; then
  echo "[inflow_outflow_capital_behavior_build] done rc=$RC dur=${dur}s $(ts)" >> "$LOG"
else
  echo "[inflow_outflow_capital_behavior_build] FAIL rc=$RC dur=${dur}s $(ts)" >> "$LOG"
fi

exit "$RC"