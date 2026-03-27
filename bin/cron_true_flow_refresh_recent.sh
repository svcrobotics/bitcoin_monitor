#!/usr/bin/env bash
set -euo pipefail

APP="/home/victor/bitcoin_monitor"
LOG="$APP/log/cron.victor.log"

# Fenêtre "récent" recalculée en FULL (corrige les zéros figés)
DAYS_BACK="${DAYS_BACK:-7}"

# Refresh exchange address set (utile si le set évolue)
EXCHANGE_ADDR_DAYS_BACK="${EXCHANGE_ADDR_DAYS_BACK:-30}"
MIN_OCC="${MIN_OCC:-8}"

# ---- rbenv bootstrap (CRON ne charge pas .bashrc/.profile) ----
export RBENV_ROOT="${RBENV_ROOT:-$HOME/.rbenv}"
export PATH="$RBENV_ROOT/bin:$RBENV_ROOT/shims:$PATH"
if command -v rbenv >/dev/null 2>&1; then
  eval "$(rbenv init - bash)"
fi

# ---- rails env ----
export RAILS_ENV="${RAILS_ENV:-development}"

ts="$(date -Is)"
ruby_v="$(ruby -v 2>/dev/null || true)"
bundle_v="$(bundle -v 2>/dev/null || echo "bundle:NOT_FOUND")"
echo "[true_flow_refresh_recent] start ${ts} ruby=${ruby_v} bundler=${bundle_v} RAILS_ENV=${RAILS_ENV} DAYS_BACK=${DAYS_BACK} EXCHANGE_ADDR_DAYS_BACK=${EXCHANGE_ADDR_DAYS_BACK} MIN_OCC=${MIN_OCC}" >> "$LOG"
t0="$(date +%s)"

cd "$APP"

# 1) refresh exchange address set (optionnel mais recommandé)
EXCHANGE_ADDR_MIN_OCC="$MIN_OCC" DAYS_BACK="$EXCHANGE_ADDR_DAYS_BACK" \
  bundle exec bin/rails exchange_true_flow:build_addresses >> "$LOG" 2>&1

# 2) FULL rebuild sur la fenêtre récente (écrase les zéros figés)
DAYS_BACK="$DAYS_BACK" \
  bundle exec bin/rails exchange_true_flow:rebuild >> "$LOG" 2>&1

rc=$?
dt="$(( $(date +%s) - t0 ))"
echo "[true_flow_refresh_recent] done rc=${rc} dur=${dt}s $(date -Is)" >> "$LOG"
exit "$rc"
