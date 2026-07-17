#!/usr/bin/env bash
set -euo pipefail

APP="/home/victor/bitcoin_monitor"
LOG="$APP/log/cron.victor.log"
LOCK="/tmp/bitcoin_monitor_whale_scan.lock"
INFO="/tmp/bitcoin_monitor_whale_scan.lockinfo"

ts(){ date -Is; }

# Tente de prendre le lock et exécute le scan si OK
if flock -n "$LOCK" -c "
  echo \"pid=$$ start=$(ts) cmd=$0\" > '$INFO'
  cd '$APP'
  /bin/bash '$APP/bin/cron_whale_scan.sh' >> '$LOG' 2>&1
  rc=\$?
  rm -f '$INFO' || true
  exit \$rc
"; then
  echo \"[whale_scan] done  $(ts) rc=0\" >> \"$LOG\"
else
  echo \"[whale_scan] skip  $(ts) rc=1 (locked)\" >> \"$LOG\"
  if [ -f \"$INFO\" ]; then
    echo \"[whale_scan] lock_owner $(ts) $(cat "$INFO")\" >> \"$LOG\"
  else
    echo \"[whale_scan] lock_owner $(ts) info=missing\" >> \"$LOG\"
  fi
fi
