# frozen_string_literal: true

require "test_helper"

class Layer1AuditProcfileTest < ActiveSupport::TestCase
  EXPECTED_ENVIRONMENT = %w[
    TANSA_PIPELINE_MODE=development_backfill
    TANSA_BACKFILL_ALTERNATING_ENABLED=true
    TANSA_BACKFILL_LAYER1_START_LAG=10
    TANSA_BACKFILL_LAYER1_STOP_LAG=2
    LAYER1_STRICT_ONLY=1
  ].freeze

  test "declares one isolated Layer1 audit Sidekiq consumer" do
    declaration = audit_declaration
    command = declaration.fetch(:command)

    assert_equal "sidekiq_layer1_audit", declaration.fetch(:name)
    assert_equal ["layer1_audit"], command.scan(/(?:\A|\s)-q\s+(\S+)/).flatten
    assert_equal ["1"], command.scan(/(?:\A|\s)-c\s+(\d+)/).flatten
    assert_equal ["19"], command.scan(/(?:\A|\s)nice\s+-n\s+(\d+)/).flatten
    assert_includes command, "bundle exec sidekiq"

    EXPECTED_ENVIRONMENT.each do |assignment|
      assert_includes command.split, assignment
    end
  end

  test "consumer embeds no scheduler producer or application integration" do
    command = audit_declaration.fetch(:command)

    refute_match(/StrictPipeline::Scheduler|\bscheduler\b/, command)
    refute_match(/perform_(?:async|in)|push_bulk|enqueue|rails runner/, command)
    refute_match(/Layer1AuditController|Layer1::Audit::BlockJob/, command)
    refute_match(/foreman|bin\/dev/, command)
  end

  test "test inspects only the named declaration without executing Procfile" do
    assert_equal 1, audit_lines.size
    assert_instance_of String, audit_declaration.fetch(:command)
  end

  private

  def audit_declaration
    line = audit_lines.fetch(0)
    name, command = line.split(":", 2)

    { name: name, command: command.to_s.strip }
  end

  def audit_lines
    @audit_lines ||=
      File.readlines(Rails.root.join("Procfile.dev"), chomp: true)
        .grep(/\Asidekiq_layer1_audit:/)
  end
end
