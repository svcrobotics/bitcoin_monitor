#!/usr/bin/env bash
set -euo pipefail

APP="/home/victor/bitcoin_monitor"
LOG="$APP/log/cron.victor.log"

mkdir -p "$APP/log"
cd "$APP"

# ---- rbenv bootstrap ----
export RBENV_ROOT="${RBENV_ROOT:-/home/victor/.rbenv}"
export PATH="$RBENV_ROOT/bin:$RBENV_ROOT/shims:$PATH"
if command -v rbenv >/dev/null 2>&1; then
  eval "$(rbenv init - bash)"
fi

# ---- env ----
export RAILS_ENV="${RAILS_ENV:-development}"
export EURUSD_RATE="${EURUSD_RATE:-1.09}"

# Fenêtre backfill : par défaut 10 jours (comme ton script actuel)
export DAYS_BACK="${DAYS_BACK:-10}"

ts="$(date -Is)"
ruby_v="$(ruby -v 2>/dev/null || true)"
bundle_v="$(bundle -v 2>/dev/null || echo "bundle:NOT_FOUND")"
echo "[btc_price_backfill] start ${ts} ruby=${ruby_v} bundler=${bundle_v} RAILS_ENV=${RAILS_ENV} EURUSD_RATE=${EURUSD_RATE} DAYS_BACK=${DAYS_BACK}" >> "$LOG"

t0="$(date +%s)"

set +e
bundle exec bin/rails runner '
days_back = ENV.fetch("DAYS_BACK", "10").to_i
days_back = 1 if days_back < 1

to   = Date.yesterday
from = to - days_back

ok = 0
fixed = 0
failed = 0

(from..to).each do |d|
  begin
    r = BtcPriceDay.find_by(day: d)

    # Skip si complet USD+EUR
    if r&.close_usd.present? && r&.close_eur.present?
      ok += 1
      next
    end

    BtcPriceDayBuilder.call(day: d)
    fixed += 1
    puts "[btc_price_backfill] fixed day=#{d}"
  rescue => e
    failed += 1
    puts "[btc_price_backfill] fail day=#{d} #{e.class}: #{e.message}"
  end
end

puts "[btc_price_backfill] summary from=#{from} to=#{to} ok=#{ok} fixed=#{fixed} failed=#{failed}"
' >> "$LOG" 2>&1
rc=$?
set -e

dt="$(( $(date +%s) - t0 ))"

if [ "$rc" -eq 0 ]; then
  echo "[btc_price_backfill] done rc=${rc} dur=${dt}s $(date -Is)" >> "$LOG"
else
  echo "[btc_price_backfill] FAIL rc=${rc} dur=${dt}s $(date -Is)" >> "$LOG"
fi

exit "$rc"
