# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20260715190000_create_cluster_actor_profile_handoffs")

class ClusterActorProfileHandoffsSchemaTest < ActiveSupport::TestCase
  TABLE = :cluster_actor_profile_handoffs

  setup do
    ClusterActorProfileHandoff.delete_all
    Cluster.delete_all
    @cluster = Cluster.create!
  end

  test "defines the durable certification identity and state columns" do
    columns = connection.columns(TABLE).index_by(&:name)

    assert_equal %w[
      id cluster_height block_hash cluster_id composition_version status attempts
      last_error_class claimed_at completed_at created_at updated_at
    ].sort, columns.keys.sort
    assert_column columns, "cluster_height", :integer, null: false, limit: 8
    assert_column columns, "block_hash", :string, null: false
    assert_column columns, "cluster_id", :integer, null: false, limit: 8
    assert_column columns, "composition_version", :integer, null: false, limit: 8
    assert_column columns, "status", :string, null: false
    assert_column columns, "attempts", :integer, null: false, limit: 4
    assert_column columns, "claimed_at", :datetime, null: true
    assert_column columns, "completed_at", :datetime, null: true
    assert_equal "pending", columns.fetch("status").default
    assert_equal "0", columns.fetch("attempts").default.to_s
  end

  test "defines deterministic claim and durable uniqueness indexes" do
    indexes = connection.indexes(TABLE).index_by(&:name)

    unique = indexes.fetch("idx_cluster_actor_handoffs_certification_version")
    assert unique.unique
    assert_equal %w[cluster_height block_hash cluster_id composition_version], unique.columns
    assert_equal %w[status cluster_height cluster_id],
      indexes.fetch("idx_cluster_actor_handoffs_claim_order").columns
    assert_equal %w[cluster_height block_hash],
      indexes.fetch("idx_cluster_actor_handoffs_height_hash").columns
    assert_equal ["cluster_id"],
      indexes.fetch("index_cluster_actor_profile_handoffs_on_cluster_id").columns
  end

  test "enforces nonnegative dimensions state and timestamp consistency" do
    assert_check_violation(cluster_height: -1)
    assert_check_violation(composition_version: 0)
    assert_check_violation(attempts: -1)
    assert_check_violation(status: "unknown")
    assert_check_violation(status: "processing", claimed_at: nil)
    assert_check_violation(status: "completed", completed_at: nil)
    assert_check_violation(status: "pending", completed_at: Time.current)
  end

  test "supports multiple clusters and idempotent replay of one certification" do
    other = Cluster.create!
    first = insert_handoff(cluster_id: @cluster.id)
    second = insert_handoff(cluster_id: other.id)

    assert first
    assert second
    assert_raises(ActiveRecord::RecordNotUnique) do
      connection.transaction(requires_new: true) do
        insert_handoff(cluster_id: @cluster.id)
      end
    end
    assert insert_handoff(cluster_id: @cluster.id, block_hash: "divergent-hash")
  end

  test "has a foreign key and excludes sensitive payload columns" do
    foreign_key = connection.foreign_keys(TABLE).sole
    assert_equal "clusters", foreign_key.to_table
    assert_equal "cluster_id", foreign_key.column

    forbidden = %w[token redis_token redis_key payload backtrace error_message metadata]
    assert_empty connection.columns(TABLE).map(&:name) & forbidden
  end

  test "migration declares a reversible create table contract" do
    source = File.read(
      Rails.root.join("db/migrate/20260715190000_create_cluster_actor_profile_handoffs.rb")
    )

    assert_match(/def change/, source)
    assert_match(/create_table :cluster_actor_profile_handoffs/, source)
    assert_no_match(/execute|Redis|Sidekiq/, source)
  end

  test "migration completes a down and up cycle in the test database" do
    migration = CreateClusterActorProfileHandoffs.new

    migration.migrate(:down)
    connection.schema_cache.clear!
    assert_not connection.table_exists?(TABLE)

    migration.migrate(:up)
    connection.schema_cache.clear!
    assert connection.table_exists?(TABLE)
  ensure
    unless connection.table_exists?(TABLE)
      migration&.migrate(:up)
      connection.schema_cache.clear!
    end
  end

  private

  def connection
    ActiveRecord::Base.connection
  end

  def assert_column(columns, name, type, null:, limit: nil)
    column = columns.fetch(name)
    assert_equal type, column.type, name
    assert_equal null, column.null, name
    assert_equal limit, column.limit, name unless limit.nil?
  end

  def assert_check_violation(**overrides)
    assert_raises(ActiveRecord::StatementInvalid) do
      connection.transaction(requires_new: true) do
        insert_handoff(**overrides)
        raise ActiveRecord::Rollback
      end
    end
  end

  def insert_handoff(cluster_height: 910_000, block_hash: "certified-hash",
    cluster_id: @cluster.id, composition_version: 1, status: "pending", attempts: 0,
    claimed_at: nil, completed_at: nil)
    values = {
      cluster_height: cluster_height,
      block_hash: block_hash,
      cluster_id: cluster_id,
      composition_version: composition_version,
      status: status,
      attempts: attempts,
      claimed_at: claimed_at,
      completed_at: completed_at,
      created_at: Time.current,
      updated_at: Time.current
    }
    columns = values.keys.map { |name| connection.quote_column_name(name) }.join(", ")
    quoted = values.values.map { |value| connection.quote(value) }.join(", ")
    connection.select_value(<<~SQL)
      INSERT INTO #{connection.quote_table_name(TABLE)} (#{columns})
      VALUES (#{quoted})
      RETURNING id
    SQL
  end
end
