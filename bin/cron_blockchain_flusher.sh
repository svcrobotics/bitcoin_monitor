#!/usr/bin/env bash
cd /home/victor/bitcoin_monitor || exit 1

export RAILS_ENV=development
export REDIS_URL=${REDIS_URL:-redis://127.0.0.1:6379/0}

export OUTPUT_FLUSH_BATCH_SIZE=${OUTPUT_FLUSH_BATCH_SIZE:-20000}
export SPENT_OUTPUT_FLUSH_BATCH_SIZE=${SPENT_OUTPUT_FLUSH_BATCH_SIZE:-10000}

echo "[START $(date)]" >> log/cron_blockchain_flusher.log

bin/rails runner 'pp Blockchain::Flushers::AllFlusherJob.perform_now' >> log/cron_blockchain_flusher.log 2>&1

echo "[END $(date)]" >> log/cron_blockchain_flusher.log