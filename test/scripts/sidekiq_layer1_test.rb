# frozen_string_literal: true

require "test_helper"
require "open3"

class SidekiqLayer1ScriptTest < ActiveSupport::TestCase
  SCRIPT_PATH = Rails.root.join("bin/sidekiq_layer1.sh")
  V2_EXPORT = 'export SPENT_OUTPUT_FLUSHER_V2="${SPENT_OUTPUT_FLUSHER_V2:-1}"'
  SIDEKIQ_COMMAND = "bundle exec sidekiq -q realtime -q process -q ingest -c 6"

  test "has valid shell syntax without executing the launcher" do
    _stdout, stderr, status = Open3.capture3("bash", "-n", SCRIPT_PATH.to_s)

    assert status.success?, stderr
  end

  test "declares v2 before sidekiq while preserving launcher behavior" do
    source = SCRIPT_PATH.read
    export_offset = source.index(V2_EXPORT)
    sidekiq_offset = source.index(SIDEKIQ_COMMAND)

    assert export_offset, "missing explicit V2 export"
    assert sidekiq_offset, "missing original Sidekiq command"
    assert_operator export_offset, :<, sidekiq_offset
    assert_equal 1, source.scan(V2_EXPORT).size
    assert_equal 1, source.scan(SIDEKIQ_COMMAND).size
    assert_equal 1, source.scan(/\bbundle exec sidekiq\b/).size
    assert_includes source, "export RAILS_MAX_THREADS=${RAILS_MAX_THREADS:-10}"
  end

  test "defaults absent and empty values to one and preserves rollback zero" do
    assert_equal "1", expanded_v2_value(nil)
    assert_equal "1", expanded_v2_value("")
    assert_equal "   ", expanded_v2_value("   ")
    assert_equal "1", expanded_v2_value("1")
    assert_equal "0", expanded_v2_value("0")
  end

  test "does not add operational side effects" do
    source = SCRIPT_PATH.read

    refute_match(/\b(?:redis-cli|psql|curl|wget)\b/, source)
    refute_match(/\b(?:systemctl|service|supervisorctl)\b/, source)
    refute_match(/\b(?:pkill|killall)\b/, source)
    refute_match(/\bcrontab\b/, source)
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
