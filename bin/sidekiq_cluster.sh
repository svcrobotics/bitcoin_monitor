#!/usr/bin/env bash
cd /home/victor/bitcoin_monitor || exit 1

export RAILS_ENV=development
export REDIS_URL=${REDIS_URL:-redis://127.0.0.1:6379/0}

export CLUSTER_SKIP_IF_LAYER1_LAG_GT=${CLUSTER_SKIP_IF_LAYER1_LAG_GT:-1000}
export CLUSTER_SCAN_LIMIT=${CLUSTER_SCAN_LIMIT:-100}

bundle exec sidekiq -q p3_clusters -c 2
