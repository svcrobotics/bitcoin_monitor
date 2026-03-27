#!/usr/bin/env bash
set -euo pipefail

APP="/home/victor/bitcoin_monitor"
LOG="$APP/log/cron.victor.log"

export RBENV_ROOT="${RBENV_ROOT:-/home/victor/.rbenv}"
export PATH="$RBENV_ROOT/bin:$RBENV_ROOT/shims:$PATH"
if command -v rbenv >/dev/null 2>&1; then
  eval "$(rbenv init - bash)"
fi

export RAILS_ENV="${RAILS_ENV:-development}"

ts="$(date -Is)"
ruby_v="$(ruby -v 2>/dev/null || true)"
bundle_v="$(bundle -v 2>/dev/null || echo "bundle:NOT_FOUND")"
echo "[btc_price_days] start ${ts} ruby=${ruby_v} bundler=${bundle_v} RAILS_ENV=${RAILS_ENV}" >> "$LOG"

t0="$(date +%s)"
cd "$APP"

set +e
bundle exec bin/rails btc_price_days:catchup >> "$LOG" 2>&1
rc=$?
set -e

dt="$(( $(date +%s) - t0 ))"

if [ "$rc" -eq 0 ]; then
  echo "[btc_price_days] done rc=${rc} dur=${dt}s $(date -Is)" >> "$LOG"
else
  echo "[btc_price_days] FAIL rc=${rc} dur=${dt}s $(date -Is)" >> "$LOG"
fi

exit "$rc"