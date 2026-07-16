# frozen_string_literal: true

require "test_helper"

class ClusterTransactionProjectionMigrationsTest < ActiveSupport::TestCase
  TABLES = %w[
    cluster_composition_revision_repair_checkpoints
    cluster_transaction_facts
    cluster_transaction_projection_backfill_addresses
    cluster_transaction_projection_backfill_items
    cluster_transaction_projection_backfill_runs
    cluster_transaction_projection_blocks
    cluster_transaction_projection_generations
  ].freeze

  test "defines the complete projection schema contract" do
    assert_equal TABLES, TABLES.select { |table| connection.table_exists?(table) }.sort

    assert_equal 46, catalog_count("pg_constraint")
    assert_equal 19, catalog_count("pg_index")
  end

  test "consolidates the temporary certified revision index" do
    indexes = connection.indexes(:cluster_transaction_projection_generations).index_by(&:name)

    refute indexes.key?("idx_ctp_generations_one_certified_revision")

    final = indexes.fetch("idx_ctp_generations_one_certified_cluster")
    assert final.unique
    assert_equal ["cluster_id"], final.columns
    assert_equal "((status)::text = 'certified'::text)", final.where
  end

  test "preserves the historical temporary index contract" do
    source = File.read(
      Rails.root.join("db/migrate/20260713180100_create_cluster_transaction_projection.rb")
    )

    assert_match(
      /\[:cluster_id, :composition_version\],\n\s+unique: true,\n\s+where: "status = 'certified'",\n\s+name: "idx_ctp_generations_one_certified_revision"/,
      source
    )
  end

  private

  def connection
    ActiveRecord::Base.connection
  end

  def catalog_count(catalog)
    quoted_tables = TABLES.map { |table| connection.quote(table) }.join(", ")
    relation = catalog == "pg_constraint" ? "conrelid" : "indrelid"

    connection.select_value(<<~SQL).to_i
      SELECT COUNT(*)
      FROM #{catalog}
      WHERE #{relation} IN (
        SELECT oid
        FROM pg_class
        WHERE relname IN (#{quoted_tables})
      )
    SQL
  end
end
