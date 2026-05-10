#!/usr/bin/env bash
cd /home/victor/bitcoin_monitor || exit 1

export RAILS_ENV=development
export REDIS_URL=${REDIS_URL:-redis://127.0.0.1:6379/0}
export RAILS_MAX_THREADS=${RAILS_MAX_THREADS:-6}

bundle exec sidekiq -q p4_analytics -q default -q low -c 2
