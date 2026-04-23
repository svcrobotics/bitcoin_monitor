#!/usr/bin/env bash
set -euo pipefail

export PATH="$HOME/.rbenv/bin:$PATH"
eval "$(rbenv init - bash)"

cd /home/victor/bitcoin_monitor

bundle exec rails btc:intraday:backfill MARKET=btcusd TF=1h LIMIT=300