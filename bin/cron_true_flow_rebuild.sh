#!/usr/bin/env bash
set -euo pipefail

APP="/home/victor/bitcoin_monitor"
LOG="$APP/log/cron.victor.log"

DAYS_BACK="${DAYS_BACK:-220}"
MIN_OCC="${MIN_OCC:-8}"

# ---- rbenv bootstrap (CRON ne charge pas .bashrc/.profile) ----
export RBENV_ROOT="${RBENV_ROOT:-$HOME/.rbenv}"
export PATH="$RBENV_ROOT/bin:$RBENV_ROOT/shims:$PATH"
if command -v rbenv >/dev/null 2>&1; then
  eval "$(rbenv init - bash)"
fi

# ---- rails env (important pour éviter "production" par défaut) ----
export RAILS_ENV="${RAILS_ENV:-development}"

ts="$(date -Is)"
ruby_v="$(ruby -v 2>/dev/null || true)"
bundle_v="$(bundle -v 2>/dev/null || echo "bundle:NOT_FOUND")"
echo "[true_flow_rebuild] start ${ts} ruby=${ruby_v} bundler=${bundle_v} RAILS_ENV=${RAILS_ENV} DAYS_BACK=${DAYS_BACK} MIN_OCC=${MIN_OCC}" >> "$LOG"
t0="$(date +%s)"

cd "$APP"

# Rebuild uniquement les jours manquants / nil (safe à lancer souvent)
EXCHANGE_ADDR_MIN_OCC="$MIN_OCC" DAYS_BACK="$DAYS_BACK" \
  bundle exec bin/rails exchange_true_flow:rebuild_missing >> "$LOG" 2>&1
rc=$?

dt="$(( $(date +%s) - t0 ))"
echo "[true_flow_rebuild] done rc=${rc} dur=${dt}s $(date -Is)" >> "$LOG"
exit "$rc"
