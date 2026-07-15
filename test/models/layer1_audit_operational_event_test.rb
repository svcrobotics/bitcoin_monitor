# frozen_string_literal: true

require "test_helper"

class Layer1AuditOperationalEventTest < ActiveSupport::TestCase
  setup do
    Layer1AuditOperationalEvent.delete_all
  end

  test "accepts every initial event type" do
    Layer1AuditOperationalEvent::EVENT_TYPES.each do |event_type|
      event = build_event(event_type: event_type)
      assert event.valid?, "#{event_type}: #{event.errors.full_messages.join(", ")}"
    end
  end

  test "accepts every initial severity" do
    Layer1AuditOperationalEvent::SEVERITIES.each do |severity|
      event = build_event(severity: severity)
      assert event.valid?, "#{severity}: #{event.errors.full_messages.join(", ")}"
    end
  end

  test "rejects unknown vocabulary" do
    assert_not build_event(event_type: "unknown").valid?
    assert_not build_event(severity: "debug").valid?
  end

  test "validates optional nonnegative integer dimensions" do
    assert build_event(audited_height: nil, defer_attempt: nil).valid?
    assert build_event(audited_height: 0, defer_attempt: 0).valid?
    assert_not build_event(audited_height: -1).valid?
    assert_not build_event(defer_attempt: -1).valid?
    assert_not build_event(audited_height: 1.5).valid?
  end

  test "requires occurred_at and object metadata" do
    assert_not build_event(occurred_at: nil).valid?
    assert build_event(metadata: {}).valid?
    assert_not build_event(metadata: []).valid?
    assert_not build_event(metadata: "value").valid?
  end

  test "persists and remains readable" do
    event = create_event(metadata: { "source" => "block_job" })

    reloaded = Layer1AuditOperationalEvent.find(event.id)
    assert_equal "already_enqueued", reloaded.event_type
    assert_equal({ "source" => "block_job" }, reloaded.metadata)
  end

  test "persisted events reject ordinary updates" do
    event = create_event

    assert_raises(ActiveRecord::ReadOnlyRecord) { event.update!(severity: "warning") }
    assert_equal "info", event.reload.severity
  end

  test "persisted events reject update_columns and touch" do
    event = create_event

    assert_raises(ActiveRecord::ReadOnlyRecord) { event.update_columns(severity: "warning") }
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.touch }
    assert_equal "info", event.reload.severity
  end

  test "persisted events reject destroy and delete" do
    event = create_event

    assert_raises(ActiveRecord::ReadOnlyRecord) { event.destroy! }
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.delete }
    assert Layer1AuditOperationalEvent.exists?(event.id)
  end

  test "has no Redis or Sidekiq dependency" do
    source = File.read(Rails.root.join("app/models/layer1_audit_operational_event.rb"))
    forbidden = [ "Red" + "is", "Side" + "kiq" ]

    forbidden.each { |constant| assert_not_includes source, constant }
  end

  private

  def build_event(**attributes)
    Layer1AuditOperationalEvent.new({
      event_type: "already_enqueued",
      severity: "info",
      occurred_at: Time.current,
      metadata: {}
    }.merge(attributes))
  end

  def create_event(**attributes)
    build_event(**attributes).tap(&:save!)
  end
end
