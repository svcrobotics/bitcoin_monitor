#!/usr/bin/env bash

cd /home/victor/bitcoin_monitor || exit 1

export RAILS_ENV=development
export CLUSTER_SCAN_LIMIT=${CLUSTER_SCAN_LIMIT:-100}

bundle exec sidekiq \
  -q p3_clusters_scan \
  -c 1