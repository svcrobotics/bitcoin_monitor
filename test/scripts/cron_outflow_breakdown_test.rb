# frozen_string_literal: true

require "test_helper"
require "open3"

class CronOutflowBreakdownTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("bin/cron_outflow_breakdown.sh")

  test "script remains a valid executable manual tool without changing its contract" do
    source = SCRIPT.read
    _stdout, stderr, status = Open3.capture3("bash", "-n", SCRIPT.to_s)

    assert status.success?, stderr
    assert_equal 0o111, File.stat(SCRIPT).mode & 0o111
    assert_includes source, 'exec "$CRON_RUN" outflow_breakdown'
    assert_includes source, "ExchangeOutflowBreakdownBuilder.call(day: Date.yesterday)"
    refute_includes source, "sidekiq"
  end
end
