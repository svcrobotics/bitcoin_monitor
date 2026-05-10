#!/usr/bin/env bash

cd /home/victor/bitcoin_monitor || exit 1

export RAILS_ENV=development

bundle exec sidekiq \
  -q p3_clusters_refresh \
  -c 1