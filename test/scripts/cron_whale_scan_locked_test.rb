# frozen_string_literal: true

require "test_helper"
require "open3"

class CronWhaleScanLockedTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("bin/cron_whale_scan_locked.sh")
  SCAN_SCRIPT = Rails.root.join("bin/cron_whale_scan.sh")

  test "script keeps the lock, logging, and Rails scan contract without executing it" do
    source = SCRIPT.read
    scan_source = SCAN_SCRIPT.read
    _stdout, stderr, status = Open3.capture3("bash", "-n", SCRIPT.to_s)

    assert status.success?, stderr
    assert_includes source, 'flock -n "$LOCK" -c "'
    assert_includes source, "/bin/bash '$APP/bin/cron_whale_scan.sh' >> '$LOG' 2>&1"
    assert_includes source, 'echo "[whale_scan] skip  $(ts) rc=1 (locked)" >> "$LOG"'
    assert_includes source, "exit \\$rc"
    assert_includes scan_source, "timeout 3600 bundle exec bin/rails whales:scan"
    refute_includes source, "bundle exec bin/rails"
  end
end
