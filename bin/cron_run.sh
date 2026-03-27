#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/home/victor/bitcoin_monitor"
cd "$APP_DIR"

# --- rbenv bootstrap (CRON does not load your shell rc files) ---
export RBENV_ROOT="${RBENV_ROOT:-$HOME/.rbenv}"
export PATH="$RBENV_ROOT/bin:$RBENV_ROOT/shims:$PATH"
if command -v rbenv >/dev/null 2>&1; then
  eval "$(rbenv init - bash)"
fi

# --- defaults (override in crontab if needed) ---
export RAILS_ENV="${RAILS_ENV:-development}"
export BUNDLE_GEMFILE="${BUNDLE_GEMFILE:-$APP_DIR/Gemfile}"

# Run command
exec bundle exec "$@"
