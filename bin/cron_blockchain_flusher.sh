#!/usr/bin/env bash
set -euo pipefail

LOCK=/tmp/bitcoin_monitor_blockchain_flusher.lock

(
  flock -n 9 || {
    echo "[SKIP $(date)] blockchain flusher already running" >> /home/victor/bitcoin_monitor/log/cron_blockchain_flusher.log
    exit 0
  }

  cd /home/victor/bitcoin_monitor || exit 1

  export RAILS_ENV=development
  export REDIS_URL=${REDIS_URL:-redis://127.0.0.1:6379/0}

  export OUTPUT_FLUSH_BATCH_SIZE=${OUTPUT_FLUSH_BATCH_SIZE:-100}
  export SPENT_OUTPUT_FLUSH_BATCH_SIZE=${SPENT_OUTPUT_FLUSH_BATCH_SIZE:-1000}
  export SPENT_OUTPUT_FLUSHER_V2="${SPENT_OUTPUT_FLUSHER_V2:-1}"

  echo "[START $(date)]" >> log/cron_blockchain_flusher.log
  bin/rails runner 'pp Blockchain::Flushers::OutputFlusher.new.call; pp Blockchain::Flushers::SpentOutputFlusherSelector.call(mode: :recovery)'
  echo "[END $(date)]" >> log/cron_blockchain_flusher.log
) 9>"$LOCK"