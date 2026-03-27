#!/usr/bin/env bash
set -euo pipefail

APP="/home/victor/bitcoin_monitor"
LOG="$APP/log/cron.victor.log"

# ---- rbenv bootstrap (CRON ne charge pas .bashrc/.profile) ----
export RBENV_ROOT="${RBENV_ROOT:-$HOME/.rbenv}"
export PATH="$RBENV_ROOT/bin:$RBENV_ROOT/shims:$PATH"
if command -v rbenv >/dev/null 2>&1; then
  eval "$(rbenv init - bash)"
fi

# ---- rails env (évite le mode production par défaut) ----
export RAILS_ENV="${RAILS_ENV:-development}"

ts="$(date -Is)"
ruby_v="$(ruby -v 2>/dev/null || true)"
bundle_v="$(bundle -v 2>/dev/null || echo "bundle:NOT_FOUND")"
echo "[market_snapshot] start ${ts} ruby=${ruby_v} bundler=${bundle_v} RAILS_ENV=${RAILS_ENV}" >> "$LOG"

t0="$(date +%s)"
cd "$APP"

# Task Rails : crée un MarketSnapshot
bundle exec bin/rails market:snapshot >> "$LOG" 2>&1
rc=$?

dt="$(( $(date +%s) - t0 ))"
echo "[market_snapshot] done rc=${rc} dur=${dt}s $(date -Is)" >> "$LOG"
exit "$rc"
