# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

class Layer1::Audit::OperationalEventRecorderTest < ActiveSupport::TestCase
  Recorder = Layer1::Audit::OperationalEventRecorder

  setup do
    Layer1AuditOperationalEvent.delete_all
  end

  test "records every supported event type" do
    Layer1AuditOperationalEvent::EVENT_TYPES.each do |event_type|
      event = Recorder.call(event_type: event_type, severity: :info)
      assert_equal event_type, event.event_type
    end
  end

  test "records every supported severity" do
    Layer1AuditOperationalEvent::SEVERITIES.each do |severity|
      event = Recorder.call(event_type: :already_enqueued, severity: severity)
      assert_equal severity, event.severity
    end
  end

  test "creates a minimal event with current time and object metadata" do
    before = Time.current
    event = Recorder.call(event_type: :already_enqueued, severity: :info)
    after = Time.current

    assert_predicate event, :persisted?
    assert_operator event.occurred_at, :>=, before
    assert_operator event.occurred_at, :<=, after
    assert_equal({}, event.metadata)
    assert_nil event.audited_height
    assert_nil event.defer_attempt
  end

  test "normalizes a complete event without retaining an exception message" do
    occurred_at = Time.zone.parse("2026-07-15 14:00:00")
    event = Recorder.call(
      event_type: :marker_cleanup_failed,
      severity: :error,
      audited_height: " 42 ",
      defer_attempt: "3",
      sidekiq_jid: " jid-123 ",
      error_class: RuntimeError.new("secret message"),
      occurred_at: occurred_at,
      metadata: { source: "block_job", nested: { attempt: 3 } }
    )

    assert_equal "marker_cleanup_failed", event.event_type
    assert_equal "error", event.severity
    assert_equal 42, event.audited_height
    assert_equal 3, event.defer_attempt
    assert_equal "jid-123", event.sidekiq_jid
    assert_equal "RuntimeError", event.error_class
    assert_equal occurred_at, event.occurred_at
    assert_equal({ "source" => "block_job", "nested" => { "attempt" => 3 } }, event.metadata)
    assert_not_includes event.attributes.to_json, "secret message"
  end

  test "strictly converts integer dimensions" do
    assert_raises(ArgumentError) do
      Recorder.call(event_type: :already_enqueued, severity: :info, audited_height: 1.5)
    end
    assert_raises(ArgumentError) do
      Recorder.call(event_type: :already_enqueued, severity: :info, defer_attempt: "1.5")
    end
  end

  test "accepts metadata at exactly 4096 serialized bytes" do
    overhead = JSON.generate({ "data" => "" }).bytesize
    metadata = { "data" => "x" * (Recorder::MAX_METADATA_BYTES - overhead) }

    event = Recorder.call(event_type: :already_enqueued, severity: :info, metadata: metadata)

    assert_equal Recorder::MAX_METADATA_BYTES, JSON.generate(event.metadata).bytesize
  end

  test "rejects metadata above 4096 serialized bytes" do
    overhead = JSON.generate({ "data" => "" }).bytesize
    metadata = { "data" => "x" * (Recorder::MAX_METADATA_BYTES - overhead + 1) }

    assert_raises(Recorder::InvalidMetadata) do
      Recorder.call(event_type: :already_enqueued, severity: :info, metadata: metadata)
    end
    assert_equal 0, Layer1AuditOperationalEvent.count
  end

  test "rejects sensitive metadata keys at the root and nested levels" do
    %w[token redis_token redis_key full_redis_key password secret backtrace error_message payload arguments].each do |key|
      assert_raises(Recorder::InvalidMetadata, key) do
        Recorder.call(event_type: :already_enqueued, severity: :info, metadata: { key => "hidden" })
      end
      assert_raises(Recorder::InvalidMetadata, "nested #{key}") do
        Recorder.call(event_type: :already_enqueued, severity: :info, metadata: { safe: { key.upcase => "hidden" } })
      end
    end
  end

  test "rejects non-object and non-JSON metadata" do
    assert_raises(Recorder::InvalidMetadata) do
      Recorder.call(event_type: :already_enqueued, severity: :info, metadata: [])
    end
    assert_raises(Recorder::InvalidMetadata) do
      Recorder.call(event_type: :already_enqueued, severity: :info, metadata: { time: Time.current })
    end
  end

  test "rejects an error message in place of an error class name" do
    assert_raises(ArgumentError) do
      Recorder.call(event_type: :marker_cleanup_failed, severity: :error, error_class: "failed to clean marker")
    end
  end

  test "bounds the cleaned Sidekiq jid" do
    event = Recorder.call(event_type: :already_enqueued, severity: :info, sidekiq_jid: " jid ")
    assert_equal "jid", event.sidekiq_jid

    assert_raises(ArgumentError) do
      Recorder.call(event_type: :already_enqueued, severity: :info, sidekiq_jid: "x" * 256)
    end
  end

  test "performs exactly one insert and returns a JSON serializable event" do
    inserts = []
    subscriber = lambda do |_name, _started, _finished, _unique_id, payload|
      inserts << payload[:sql] if payload[:sql].match?(/\AINSERT INTO "layer1_audit_operational_events"/)
    end

    event = ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      Recorder.call(event_type: :deferred_exhausted, severity: :warning, audited_height: 21)
    end

    assert_equal 1, inserts.size
    assert_nothing_raised { JSON.generate(event.as_json) }
  end

  test "propagates PostgreSQL errors" do
    failure = ActiveRecord::StatementInvalid.new("database unavailable")

    Layer1AuditOperationalEvent.stub(:create!, ->(**) { raise failure }) do
      raised = assert_raises(ActiveRecord::StatementInvalid) do
        Recorder.call(event_type: :already_enqueued, severity: :info)
      end
      assert_same failure, raised
    end
  end

  test "has no Redis or Sidekiq dependency" do
    source = File.read(Rails.root.join("app/services/layer1/audit/operational_event_recorder.rb"))
    forbidden = [ "Red" + "is", "Side" + "kiq" ]

    forbidden.each { |constant| assert_not_includes source, constant }
  end
end
