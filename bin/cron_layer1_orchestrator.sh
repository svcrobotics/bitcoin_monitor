#!/usr/bin/env bash
set -euo pipefail

LOCK=/tmp/bitcoin_monitor_layer1_orchestrator.lock

(
  flock -n 9 || {
    echo "[SKIP $(date)] layer1 orchestrator already running" >> /home/victor/bitcoin_monitor/log/cron_layer1_orchestrator.log
    exit 0
  }

  cd /home/victor/bitcoin_monitor || exit 1

  export RAILS_ENV=development
  export REDIS_URL=${REDIS_URL:-redis://127.0.0.1:6379/0}
  export OUTPUT_FLUSH_BATCH_SIZE=${OUTPUT_FLUSH_BATCH_SIZE:-2000}
  export SPENT_OUTPUT_FLUSH_BATCH_SIZE=${SPENT_OUTPUT_FLUSH_BATCH_SIZE:-2000}

  echo "[START $(date)]" >> log/cron_layer1_orchestrator.log
  bin/rails runner 'pp Blockchain::Orchestration::Layer1OrchestratorJob.perform_now' >> log/cron_layer1_orchestrator.log 2>&1
  echo "[END $(date)]" >> log/cron_layer1_orchestrator.log
) 9>"$LOCK"