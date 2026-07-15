# frozen_string_literal: true

require "test_helper"

class ClusterCompositionVersionContractTest < ActiveSupport::TestCase
  test "composition version is a non-null bigint defaulting to one" do
    column = Cluster.columns_hash.fetch("composition_version")

    assert_equal :integer, column.type
    assert_equal 8, column.limit
    assert_not column.null
    assert_equal "1", column.default
    assert_equal 1, Cluster.new.composition_version
  end

  test "nil composition version is rejected" do
    cluster = Cluster.new(composition_version: nil)

    assert_not cluster.valid?
    assert cluster.errors.added?(:composition_version, :blank)
  end

  test "zero composition version is rejected" do
    cluster = Cluster.new(composition_version: 0)

    assert_not cluster.valid?
    assert cluster.errors.added?(
      :composition_version,
      :greater_than_or_equal_to,
      count: 1,
      value: 0
    )
  end

  test "negative composition version is rejected" do
    cluster = Cluster.new(composition_version: -1)

    assert_not cluster.valid?
    assert cluster.errors.added?(
      :composition_version,
      :greater_than_or_equal_to,
      count: 1,
      value: -1
    )
  end

  test "positive composition version is persisted and incremented" do
    cluster = Cluster.create!(composition_version: 3)

    assert_equal 3, cluster.reload.composition_version

    cluster.increment!(:composition_version)

    assert_equal 4, cluster.reload.composition_version
  end

  test "database constraint is present and validated" do
    constraint =
      ActiveRecord::Base.connection.select_one(<<~SQL.squish)
        SELECT pg_get_constraintdef(oid) AS definition,
               convalidated
        FROM pg_constraint
        WHERE conrelid = 'clusters'::regclass
          AND conname = 'clusters_composition_version_positive'
      SQL

    assert constraint
    assert_equal true, constraint.fetch("convalidated")
    assert_match(/composition_version >= 1/, constraint.fetch("definition"))
  end

  test "database constraint rejects a nonpositive direct insert" do
    assert_raises(ActiveRecord::StatementInvalid) do
      Cluster.insert_all!([
        {
          composition_version: 0,
          created_at: Time.current,
          updated_at: Time.current
        }
      ])
    end
  end

  test "composition contract adds no runtime pipeline dependency" do
    model_source =
      File.read(Rails.root.join("app/models/cluster.rb"))
    migration_source =
      File.read(
        Rails.root.join(
          "db/migrate/20260713180000_contract_cluster_composition_version.rb"
        )
      )

    contract_source = [
      model_source.lines.first(17).join,
      migration_source
    ].join

    assert_no_match(/Redis|Sidekiq|BlockBuffer|ClusterInput/, contract_source)
  end
end
