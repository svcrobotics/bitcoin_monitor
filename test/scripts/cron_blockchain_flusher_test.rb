# frozen_string_literal: true

require "test_helper"
require "open3"

class CronBlockchainFlusherTest < ActiveSupport::TestCase
  SCRIPT_PATH = Rails.root.join("bin/cron_blockchain_flusher.sh")
  V2_EXPORT = 'export SPENT_OUTPUT_FLUSHER_V2="${SPENT_OUTPUT_FLUSHER_V2:-1}"'

  test "has valid shell syntax without executing the script" do
    _stdout, stderr, status = Open3.capture3("bash", "-n", SCRIPT_PATH.to_s)

    assert status.success?, stderr
  end

  test "defaults v2 to one while preserving an explicit zero" do
    source = SCRIPT_PATH.read

    assert_includes source, V2_EXPORT
    assert_equal "1", expanded_v2_value(nil)
    assert_equal "1", expanded_v2_value("")
    assert_equal "1", expanded_v2_value("1")
    assert_equal "0", expanded_v2_value("0")
  end

  test "routes only the spent flush through the selector in recovery mode" do
    source = SCRIPT_PATH.read

    assert_includes source, "Blockchain::Flushers::OutputFlusher.new.call"
    assert_includes(
      source,
      "Blockchain::Flushers::SpentOutputFlusherSelector.call(mode: :recovery)"
    )
    refute_match(/Blockchain::Flushers::SpentOutputFlusher\.new/, source)
  end

  test "does not mutate cron systemd or process state" do
    source = SCRIPT_PATH.read

    refute_match(/\bcrontab\b/, source)
    refute_match(/\bsystemctl\b/, source)
    refute_match(/\b(?:service|supervisorctl)\s+\S+\s+(?:restart|start|stop)\b/, source)
    refute_match(/\b(?:pkill|killall)\b/, source)
  end

  test "preserves the operational shell contract" do
    source = SCRIPT_PATH.read

    assert source.start_with?("#!/usr/bin/env bash\nset -euo pipefail\n")
    assert_includes source, "LOCK=/tmp/bitcoin_monitor_blockchain_flusher.lock"
    assert_includes source, "flock -n 9"
    assert_includes source, "cd /home/victor/bitcoin_monitor || exit 1"
    assert_includes source, "export RAILS_ENV=development"
    assert_includes source, 'export REDIS_URL=${REDIS_URL:-redis://127.0.0.1:6379/0}'
    assert_includes source, 'export OUTPUT_FLUSH_BATCH_SIZE=${OUTPUT_FLUSH_BATCH_SIZE:-100}'
    assert_includes source, 'export SPENT_OUTPUT_FLUSH_BATCH_SIZE=${SPENT_OUTPUT_FLUSH_BATCH_SIZE:-1000}'
    assert_includes source, 'echo "[START $(date)]" >> log/cron_blockchain_flusher.log'
    assert_includes source, 'echo "[END $(date)]" >> log/cron_blockchain_flusher.log'
    assert_includes source, ') 9>"$LOCK"'
  end

  private

  def expanded_v2_value(value)
    environment = {}
    environment["SPENT_OUTPUT_FLUSHER_V2"] = value unless value.nil?

    stdout, stderr, status = Open3.capture3(
      environment,
      "bash",
      "-c",
      "#{V2_EXPORT}; printf '%s' \"$SPENT_OUTPUT_FLUSHER_V2\""
    )

    assert status.success?, stderr
    stdout
  end
end
