#!/usr/bin/env bash
set -euo pipefail

JOB_NAME="${1:?missing job name}"
LOCK_FILE="${2:?missing lock file}"
shift 2

APP="${APP:-$(cd "$(dirname "$0")/.." && pwd)}"
LOG="${LOG:-$APP/log/cron.victor.log}"
SCHEDULED_FOR="${SCHEDULED_FOR:-}"
TRIGGERED_BY="${TRIGGERED_BY:-cron}"

cd "$APP"

export RBENV_ROOT="${RBENV_ROOT:-/home/victor/.rbenv}"
export PATH="$RBENV_ROOT/bin:$RBENV_ROOT/shims:$PATH"
if command -v rbenv >/dev/null 2>&1; then
  eval "$(rbenv init - bash)"
fi

export BUNDLE_GEMFILE="${BUNDLE_GEMFILE:-$APP/Gemfile}"
export RAILS_ENV="${RAILS_ENV:-development}"

if ! flock -n "$LOCK_FILE" true; then
  echo "[$(date '+%F %T')] [${JOB_NAME}] skipped: lock busy" >> "$LOG"

  if [ -n "$SCHEDULED_FOR" ]; then
    bundle exec bin/rails runner "JobRunner.skip!(\"${JOB_NAME}\", reason: \"lock busy\", triggered_by: \"${TRIGGERED_BY}\", scheduled_for: \"${SCHEDULED_FOR}\")" >> "$LOG" 2>&1 || true
  else
    bundle exec bin/rails runner "JobRunner.skip!(\"${JOB_NAME}\", reason: \"lock busy\", triggered_by: \"${TRIGGERED_BY}\")" >> "$LOG" 2>&1 || true
  fi

  exit 0
fi

exec flock -n "$LOCK_FILE" env \
  RBENV_ROOT="$RBENV_ROOT" \
  PATH="$PATH" \
  BUNDLE_GEMFILE="$BUNDLE_GEMFILE" \
  RAILS_ENV="$RAILS_ENV" \
  APP="$APP" \
  LOG="$LOG" \
  SCHEDULED_FOR="$SCHEDULED_FOR" \
  TRIGGERED_BY="$TRIGGERED_BY" \
  bash -c "$*"