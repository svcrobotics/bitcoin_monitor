# frozen_string_literal: true

require "test_helper"

class Layer1AuditOperationalEventsSchemaTest < ActiveSupport::TestCase
  TABLE = :layer1_audit_operational_events

  test "defines the exact operational event columns" do
    assert connection.table_exists?(TABLE)

    columns = connection.columns(TABLE).index_by(&:name)
    assert_equal %w[
      id event_type severity audited_height defer_attempt sidekiq_jid error_class
      occurred_at metadata
    ].sort, columns.keys.sort

    assert_column columns, "event_type", :string, null: false
    assert_column columns, "severity", :string, null: false
    assert_column columns, "audited_height", :integer, null: true, limit: 8
    assert_column columns, "defer_attempt", :integer, null: true, limit: 4
    assert_column columns, "sidekiq_jid", :string, null: true
    assert_column columns, "error_class", :string, null: true
    assert_column columns, "occurred_at", :datetime, null: false, precision: 6
    assert_column columns, "metadata", :jsonb, null: false

    metadata_default = columns.fetch("metadata").default
    metadata_default = JSON.parse(metadata_default) if metadata_default.is_a?(String)
    assert_equal({}, metadata_default)

    forbidden = %w[created_at updated_at token redis_token redis_key full_redis_key error_message backtrace payload]
    assert_empty columns.keys & forbidden
  end

  test "defines only the three operational read indexes" do
    indexes = connection.indexes(TABLE).sort_by(&:name)

    assert_equal %w[
      idx_layer1_audit_events_height_occurred_at
      idx_layer1_audit_events_occurred_at
      idx_layer1_audit_events_type_occurred_at
    ], indexes.map(&:name)
    assert_equal [
      %w[audited_height occurred_at],
      %w[occurred_at],
      %w[event_type occurred_at]
    ], indexes.map(&:columns)
    assert indexes.none?(&:unique)
  end

  test "defines stable nonnegative and json object constraints" do
    constraints = connection.check_constraints(TABLE).index_by(&:name)

    assert_equal %w[
      layer1_audit_events_attempt_check
      layer1_audit_events_height_check
      layer1_audit_events_metadata_object_check
    ], constraints.keys.sort
    assert_match(/audited_height IS NULL OR audited_height >= 0/, constraints.fetch("layer1_audit_events_height_check").expression)
    assert_match(/defer_attempt IS NULL OR defer_attempt >= 0/, constraints.fetch("layer1_audit_events_attempt_check").expression)
    assert_match(/jsonb_typeof\(metadata\) = 'object'/, constraints.fetch("layer1_audit_events_metadata_object_check").expression)
  end

  test "accepts a minimal event and nullable optional fields" do
    with_rolled_back_insert do
      id = insert_event
      row = connection.select_one("SELECT * FROM #{connection.quote_table_name(TABLE)} WHERE id = #{Integer(id)}")

      assert_equal "already_enqueued", row.fetch("event_type")
      assert_equal "info", row.fetch("severity")
      assert_nil row.fetch("audited_height")
      assert_nil row.fetch("defer_attempt")
      assert_nil row.fetch("sidekiq_jid")
      assert_nil row.fetch("error_class")
    end
  end

  test "rejects negative heights and defer attempts" do
    assert_check_violation(audited_height: -1)
    assert_check_violation(defer_attempt: -1)
  end

  test "rejects json arrays and scalar metadata" do
    assert_check_violation(metadata: [])
    assert_check_violation(metadata: "scalar")
    assert_check_violation(metadata: 7)
  end

  test "retains json objects" do
    with_rolled_back_insert do
      id = insert_event(metadata: { "source" => "block_job", "nested" => { "attempt" => 2 } })
      value = connection.select_value(
        "SELECT metadata FROM #{connection.quote_table_name(TABLE)} WHERE id = #{Integer(id)}"
      )

      assert_equal({ "source" => "block_job", "nested" => { "attempt" => 2 } }, JSON.parse(value))
    end
  end

  test "migration is reversible and has no runtime infrastructure dependency" do
    migration_path = Rails.root.join("db/migrate/20260715134221_create_layer1_audit_operational_events.rb")
    source = File.read(migration_path)

    assert_match(/def change/, source)
    assert_no_match(/Redis/, source)
    assert_no_match(/Sidekiq/, source)
  end

  private

  def connection
    ActiveRecord::Base.connection
  end

  def assert_column(columns, name, type, null:, limit: nil, precision: nil)
    column = columns.fetch(name)
    assert_equal type, column.type, name
    assert_equal null, column.null, name
    assert_equal limit, column.limit, name unless limit.nil?
    assert_equal precision, column.precision, name unless precision.nil?
  end

  def with_rolled_back_insert
    connection.transaction(requires_new: true) do
      yield
      raise ActiveRecord::Rollback
    end
  end

  def assert_check_violation(**attributes)
    assert_raises(ActiveRecord::StatementInvalid) do
      with_rolled_back_insert { insert_event(**attributes) }
    end
  end

  def insert_event(event_type: "already_enqueued", severity: "info", audited_height: nil,
    defer_attempt: nil, sidekiq_jid: nil, error_class: nil, occurred_at: Time.current,
    metadata: {})
    values = {
      event_type: event_type,
      severity: severity,
      audited_height: audited_height,
      defer_attempt: defer_attempt,
      sidekiq_jid: sidekiq_jid,
      error_class: error_class,
      occurred_at: occurred_at,
      metadata: JSON.generate(metadata)
    }
    columns = values.keys.map { |name| connection.quote_column_name(name) }.join(", ")
    quoted_values = values.values.map { |value| connection.quote(value) }.join(", ")

    connection.select_value(<<~SQL)
      INSERT INTO #{connection.quote_table_name(TABLE)} (#{columns})
      VALUES (#{quoted_values})
      RETURNING id
    SQL
  end
end
