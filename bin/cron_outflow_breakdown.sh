#!/usr/bin/env bash
set -euo pipefail
exec "$CRON_RUN" outflow_breakdown "bin/rails runner 'ExchangeOutflowBreakdownBuilder.call(day: Date.yesterday)'"