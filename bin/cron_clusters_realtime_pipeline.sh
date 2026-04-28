#!/usr/bin/env bash
set -euo pipefail

cd /home/victor/bitcoin_monitor

export PATH="$HOME/.rbenv/bin:$PATH"
eval "$(rbenv init - bash)"

flock -n /tmp/clusters_realtime_pipeline.lock \
  bin/rails runner 'Clusters::RealtimePipelineJob.perform_now'
