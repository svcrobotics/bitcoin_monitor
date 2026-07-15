#!/usr/bin/env bash
cd /home/victor/bitcoin_monitor || exit 1

export RAILS_ENV=development
export REDIS_URL=${REDIS_URL:-redis://127.0.0.1:6379/0}
export RAILS_MAX_THREADS=${RAILS_MAX_THREADS:-10}
export SPENT_OUTPUT_FLUSHER_V2="${SPENT_OUTPUT_FLUSHER_V2:-1}"

bundle exec sidekiq -q realtime -q process -q ingest -c 6
