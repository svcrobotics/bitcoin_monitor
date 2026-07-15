# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

class ClusterScannerStrictIsolationTest < ActiveSupport::TestCase
  FORBIDDEN_WRITE_TABLES = %w[
    cluster_inputs
    actor_profiles
    actor_labels
    actor_behavior_heavy_snapshots
    cluster_activity_states
    scanner_cursors
  ].freeze

  setup do
    AddressLink.delete_all
    ClusterInput.delete_all
    Address.delete_all
    Cluster.delete_all
  end

  test "materializes one exact height without external side effects" do
    height = 920_100
    inputs = create_inputs!(height: height, txid: "strict-a", addresses: %w[scan-a scan-b])
    create_inputs!(height: height + 1, txid: "strict-other", addresses: %w[other-a other-b])
    timestamps = inputs.to_h { |input| [input.id, input.updated_at] }

    sql = capture_sql do
      Redis.stub(:new, ->(*) { flunk("Redis must not be initialized") }) do
        @result = scan(height)
      end
    end

    assert_equal height, @result[:height]
    assert_equal [height], @result[:heights]
    assert_equal 2, @result[:input_rows_found]
    assert_equal 2, @result[:addresses_created]
    assert_equal 2, @result[:addresses_touched]
    assert_equal 1, @result[:links_created]
    assert_equal 1, @result[:clusters_created]
    assert_equal 1, @result[:clusters_touched_count]
    assert_equal 1, @result.dig(:clusters_touched, 0, :composition_version)
    assert_nil Address.find_by(address: "other-a")
    inputs.each { |input| assert_equal timestamps.fetch(input.id), input.reload.updated_at }
    assert_sql_isolation(sql)
    assert JSON.generate(@result)
  end

  test "cluster changes are unique sorted deterministic and carry persisted versions" do
    height = 920_110
    first = Cluster.create!(composition_version: 2)
    second = Cluster.create!(composition_version: 5)
    Address.create!(address: "version-a", cluster: first)
    Address.create!(address: "version-b", cluster: second)
    create_inputs!(height: height, txid: "version-tx", addresses: %w[version-b version-a])

    result = scan(height)
    touched = result[:clusters_touched]

    assert_equal touched.sort_by { |entry| entry[:cluster_id] }, touched
    assert_equal touched.map { |entry| entry[:cluster_id] }.uniq, touched.map { |entry| entry[:cluster_id] }
    assert_equal [first.id, second.id].sort, touched.map { |entry| entry[:cluster_id] }
    touched.each do |entry|
      assert_equal Cluster.find(entry[:cluster_id]).composition_version, entry[:composition_version]
    end
  end

  test "second identical scan is idempotent and reports no composition change" do
    height = 920_200
    create_inputs!(height: height, txid: "repeat-tx", addresses: %w[repeat-a repeat-b])

    first = scan(height)
    counts = [Cluster.count, Address.count, AddressLink.count]
    versions = Cluster.order(:id).pluck(:id, :composition_version)
    second = scan(height)

    assert_equal 1, first[:links_created]
    assert_equal counts, [Cluster.count, Address.count, AddressLink.count]
    assert_equal versions, Cluster.order(:id).pluck(:id, :composition_version)
    assert_equal 0, second[:links_created]
    assert_equal [], second[:clusters_touched]
    assert_equal 0, second[:clusters_touched_count]
  end

  test "a mutation error rolls back addresses clusters and links" do
    height = 920_300
    create_inputs!(height: height, txid: "rollback-tx", addresses: %w[rollback-a rollback-b])
    original = Clusters::ClusterMerger.method(:call)
    failure = ->(**) { raise "merger failed" }

    Clusters::ClusterMerger.define_singleton_method(:call, &failure)
    assert_raises(ClusterScanner::Error) { scan(height) }

    assert_equal 0, Address.count
    assert_equal 0, Cluster.count
    assert_equal 0, AddressLink.count
  ensure
    Clusters::ClusterMerger.define_singleton_method(:call) { |**args| original.call(**args) } if original
  end

  test "requires a bounded explicit range and refuses external refresh" do
    assert_raises(ArgumentError) { ClusterScanner.call }
    assert_raises(ArgumentError) { ClusterScanner.call(from_height: 10, to_height: 9) }
    assert_raises(ArgumentError) { ClusterScanner.call(height: 10, refresh: true) }
  end

  test "installed scanner contains no Redis Sidekiq or downstream publication" do
    source = File.read(Rails.root.join("app/services/cluster_scanner.rb"))

    refute_match(/Redis|Sidekiq|perform_(?:later|async|in)/, source)
    refute_match(/DirtyClusterQueue|DirtyMarker|ActorProfile|ActorLabel|ActorBehavior/, source)
    refute_match(/ClickHouse|JobRunner|ScannerCursor/, source)
    refute_match(/tx_outputs|utxo_outputs|cluster_processed_at/, source)
  end

  private

  def scan(height)
    ClusterScanner.call(height: height, mode: :batch)
  end

  def create_inputs!(height:, txid:, addresses:)
    addresses.each_with_index.map do |address, index|
      ClusterInput.create!(
        block_height: height - 1,
        txid: "source-#{txid}-#{index}",
        vout: index,
        address: address,
        amount_btc: "1.00000000",
        spent: true,
        spent_txid: txid,
        spent_block_height: height
      )
    end
  end

  def capture_sql
    statements = []
    subscriber = lambda do |_name, _start, _finish, _id, payload|
      statements << payload[:sql].to_s unless payload[:name] == "SCHEMA"
    end
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
    statements
  end

  def assert_sql_isolation(statements)
    statements.each do |statement|
      normalized = statement.squish
      FORBIDDEN_WRITE_TABLES.each do |table|
        refute_match(
          /\A(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+\"?#{Regexp.escape(table)}\"?/i,
          normalized
        )
      end
      refute_match(/\b(?:tx_outputs|utxo_outputs)\b/i, normalized)
    end
  end
end
