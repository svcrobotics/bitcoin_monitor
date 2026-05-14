#!/usr/bin/env bash
set -euo pipefail

APP="/home/victor/bitcoin_monitor"
LOG="$APP/log/cron_cluster_refresh_dirty_clusters.log"
LOCK="/tmp/bitcoin_monitor_cluster_refresh_dirty_clusters.lock"

mkdir -p "$APP/log"
cd "$APP"

export RBENV_ROOT="${RBENV_ROOT:-/home/victor/.rbenv}"
export PATH="$RBENV_ROOT/bin:$RBENV_ROOT/shims:$PATH"

if command -v rbenv >/dev/null 2>&1; then
  eval "$(rbenv init - bash)"
fi

export RAILS_ENV="${RAILS_ENV:-development}"
export TRIGGERED_BY="${TRIGGERED_BY:-cron}"

{
  echo "[cluster_refresh] start $(date '+%F %T')"

  flock -n "$LOCK" bin/rails runner '
    result = Clusters::RefreshDirtyClustersJob.perform_now
    pp result
    pp dirty_queue_size: Clusters::DirtyClusterQueue.size
  '

  echo "[cluster_refresh] done $(date '+%F %T')"
} >> "$LOG" 2>&1