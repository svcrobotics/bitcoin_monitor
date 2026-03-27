#!/usr/bin/env bash
set -euo pipefail

APP="/home/victor/bitcoin_monitor"
LOG="$APP/log/recover_after_reboot.log"
RAILS_ENV="${RAILS_ENV:-development}"

N="${N:-500}"
WHALE_MIN_BTC="${WHALE_MIN_BTC:-500}"

BITCOIND_SERVICE="${BITCOIND_SERVICE:-bitcoind}"
BTC_DATADIR="${BTC_DATADIR:-/mnt/bitcoin}"
RPC_TIMEOUT_SEC="${RPC_TIMEOUT_SEC:-180}"

PAUSE_CRON="${PAUSE_CRON:-0}"

mkdir -p "$(dirname "$LOG")"

log() { echo "[$(date -Is)] $*" | tee -a "$LOG"; }
die() { log "❌ $*"; exit 1; }

run_as_victor() { sudo -u victor -H bash -lc "$*"; }

# --- Pretty helpers ---
hr() { log "------------------------------------------------------------"; }

# Prefix every line with a tag
prefix_lines() {
  local tag="$1"
  sed -u "s/^/[$tag] /"
}

# Run a command, stream output to console+log, prefixing lines.
run_cmd() {
  local tag="$1"; shift
  # Use stdbuf so logs are flushed line-by-line
  stdbuf -oL -eL "$@" 2>&1 | prefix_lines "$tag" | tee -a "$LOG"
}

# Step wrapper: start/end + duration + exit code
run_step() {
  local name="$1"; shift
  local start_ts end_ts dur rc
  hr
  log "▶️  START: $name"
  start_ts="$(date +%s)"

  set +e
  run_cmd "$name" "$@"
  rc="${PIPESTATUS[0]}"
  set -e

  end_ts="$(date +%s)"
  dur="$((end_ts - start_ts))"

  if [[ "$rc" -ne 0 ]]; then
    log "❌ FAIL:  $name (rc=$rc, dur=${dur}s)"
    exit "$rc"
  fi

  log "✅ DONE:  $name (dur=${dur}s)"
}

# Bitcoind progress snapshot (works when RPC up)
bitcoind_progress() {
  bitcoin-cli -datadir="$BTC_DATADIR" getblockchaininfo 2>/dev/null \
    | ruby -rjson -e '
        j=JSON.parse(STDIN.read);
        b=j["blocks"]; h=j["headers"];
        ibd=j["initialblockdownload"];
        vp=j["verificationprogress"];
        vp_pct=(vp*100.0);
        puts "blocks=#{b} headers=#{h} ibd=#{ibd} verify=#{sprintf("%.2f", vp_pct)}%";
      ' 2>/dev/null || true
}

log "=== recover_after_reboot start ==="
log "RAILS_ENV=$RAILS_ENV N=$N WHALE_MIN_BTC=$WHALE_MIN_BTC"

if [[ "$PAUSE_CRON" == "1" ]]; then
  run_step "cron:stop" sudo systemctl stop cron || true
fi

run_step "bitcoind:ensure_started" sudo systemctl start "$BITCOIND_SERVICE" || true

# Wait for RPC, but also show progress every 5s while waiting
hr
log "▶️  START: bitcoind:rpcwait (timeout=${RPC_TIMEOUT_SEC}s)"
start_ts="$(date +%s)"
until bitcoin-cli -datadir="$BTC_DATADIR" -rpcwait getblockchaininfo >/dev/null 2>&1; do
  now="$(date +%s)"
  if (( now - start_ts > RPC_TIMEOUT_SEC )); then
    die "bitcoind RPC not ready after ${RPC_TIMEOUT_SEC}s (service=$BITCOIND_SERVICE datadir=$BTC_DATADIR)"
  fi
  log "⏳ waiting RPC... $(bitcoind_progress)"
  sleep 5
done
log "✅ DONE:  bitcoind:rpcwait $(bitcoind_progress)"

# Bundler check (victor)
run_step "bundle:check" bash -lc "
  sudo -u victor -H bash -lc '
    set -euo pipefail
    cd \"$APP\"
    export RAILS_ENV=\"$RAILS_ENV\"
    export RBENV_ROOT=\"/home/victor/.rbenv\"
    export PATH=\"\$RBENV_ROOT/bin:\$RBENV_ROOT/shims:\$PATH\"
    eval \"\$(rbenv init - bash)\"
    ruby -v
    bundle -v
    bundle check
  '
"

# btc price daily
run_step "btc_price_daily" bash -lc "
  sudo -u victor -H bash -lc '
    set -euo pipefail
    cd \"$APP\"
    export RAILS_ENV=\"$RAILS_ENV\"
    export RBENV_ROOT=\"/home/victor/.rbenv\"
    export PATH=\"\$RBENV_ROOT/bin:\$RBENV_ROOT/shims:\$PATH\"
    eval \"\$(rbenv init - bash)\"
    /bin/bash \"$APP/bin/cron_btc_price_daily.sh\"
  '
"

# market snapshot
run_step "market_snapshot" bash -lc "
  sudo -u victor -H bash -lc '
    set -euo pipefail
    cd \"$APP\"
    export RAILS_ENV=\"$RAILS_ENV\"
    export RBENV_ROOT=\"/home/victor/.rbenv\"
    export PATH=\"\$RBENV_ROOT/bin:\$RBENV_ROOT/shims:\$PATH\"
    eval \"\$(rbenv init - bash)\"
    /bin/bash \"$APP/bin/cron_market_snapshot.sh\"
  '
"

# whale scan
run_step "whale_scan(N=$N)" bash -lc "
  sudo -u victor -H bash -lc '
    set -euo pipefail
    cd \"$APP\"
    export RAILS_ENV=\"$RAILS_ENV\"
    export RBENV_ROOT=\"/home/victor/.rbenv\"
    export PATH=\"\$RBENV_ROOT/bin:\$RBENV_ROOT/shims:\$PATH\"
    eval \"\$(rbenv init - bash)\"
    export N=\"$N\"
    export WHALE_MIN_BTC=\"$WHALE_MIN_BTC\"
    bundle exec rails runner tmp/cron_whale_scan.rb
  '
"

# true flow rebuild
run_step "true_flow_rebuild" bash -lc "
  sudo -u victor -H bash -lc '
    set -euo pipefail
    cd \"$APP\"
    export RAILS_ENV=\"$RAILS_ENV\"
    export RBENV_ROOT=\"/home/victor/.rbenv\"
    export PATH=\"\$RBENV_ROOT/bin:\$RBENV_ROOT/shims:\$PATH\"
    eval \"\$(rbenv init - bash)\"
    /bin/bash \"$APP/bin/cron_true_flow_rebuild.sh\"
  '
"

# outflow daily (optional)
hr
log "▶️  START: true_flow_outflow_daily (optional)"
set +e
bash -lc "
  sudo -u victor -H bash -lc '
    set -euo pipefail
    cd \"$APP\"
    export RAILS_ENV=\"$RAILS_ENV\"
    export RBENV_ROOT=\"/home/victor/.rbenv\"
    export PATH=\"\$RBENV_ROOT/bin:\$RBENV_ROOT/shims:\$PATH\"
    eval \"\$(rbenv init - bash)\"
    /bin/bash \"$APP/bin/cron_true_flow_outflow_daily.sh\"
  '
" 2>&1 | prefix_lines "true_flow_outflow_daily" | tee -a "$LOG"
rc="${PIPESTATUS[0]}"
set -e
if [[ "$rc" -ne 0 ]]; then
  log "⚠️  SKIP/FAIL: true_flow_outflow_daily rc=$rc (ignored)"
else
  log "✅ DONE: true_flow_outflow_daily"
fi

if [[ "$PAUSE_CRON" == "1" ]]; then
  run_step "cron:start" sudo systemctl start cron || true
fi

hr
log "=== recover_after_reboot done ✅ ==="
