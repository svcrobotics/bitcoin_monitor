# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

class ClusterScannerStrictIsolationTest < ActiveSupport::TestCase
  class FakeRedis
    def set(*) = true
    def del(*) = 1
  end

  setup do
    AddressLink.delete_all
    ClusterInput.delete_all
    Address.delete_all
    Cluster.delete_all
    BlockBufferModel.delete_all
  end

  test "strict height scan materializes provenance without mutating Layer1 facts" do
    height = 920_100
    other_height = height + 1
    cluster = Cluster.create!
    first = Address.create!(address: "strict-isolation-a", cluster: cluster)
    second = Address.create!(address: "strict-isolation-b", cluster: cluster)
    marker = 2.days.ago.change(usec: 0)

    BlockBufferModel.create!(
      height: other_height,
      block_hash: "strict-isolation-block",
      status: "processed"
    )
    inputs =
      create_inputs!(
        height: height,
        txid: "strict-isolation-tx",
        addresses: [first.address, second.address],
        marker: marker
      )
    create_inputs!(
      height: other_height,
      txid: "strict-other-height-tx",
      addresses: %w[strict-other-a strict-other-b],
      marker: nil
    )
    original_timestamps = inputs.to_h { |input| [input.id, input.updated_at] }
    sql = capture_sql do
      scan(height)
    end

    inputs.each do |input|
      reloaded = input.reload
      assert_equal marker, reloaded.cluster_processed_at
      assert_equal original_timestamps.fetch(input.id), reloaded.updated_at
    end
    assert_nil Address.find_by(address: "strict-other-a")
    assert_equal 1, AddressLink.where(
      txid: "strict-isolation-tx",
      block_height: height,
      link_type: "multi_input"
    ).count
    assert_equal cluster.id, first.reload.cluster_id
    assert_equal cluster.id, second.reload.cluster_id
    assert_no_forbidden_sql(sql)
  end

  test "a second identical scan creates no duplicate Cluster object or link" do
    height = 920_200
    cluster = Cluster.create!
    first = Address.create!(address: "strict-idempotent-a", cluster: cluster)
    second = Address.create!(address: "strict-idempotent-b", cluster: cluster)

    BlockBufferModel.create!(
      height: height,
      block_hash: "strict-idempotent-block",
      status: "processed"
    )
    create_inputs!(
      height: height,
      txid: "strict-idempotent-tx",
      addresses: [first.address, second.address],
      marker: nil
    )

    scan(height)
    counts = [Cluster.count, Address.count, AddressLink.count]
    scan(height)

    assert_equal counts, [Cluster.count, Address.count, AddressLink.count]
    assert_equal 1, AddressLink.where(txid: "strict-idempotent-tx").count
  end

  private

  def scan(height)
    ::Redis.stub(:new, FakeRedis.new) do
      Clusters::DirtyClusterQueue.stub(:add, true) do
        Clusters::DirtyClusterQueue.stub(:size, 0) do
          ClusterScanner.call(
            from_height: height,
            to_height: height,
            mode: :batch,
            refresh: false
          )
        end
      end
    end
  end

  def create_inputs!(height:, txid:, addresses:, marker:)
    addresses.each_with_index.map do |address, index|
      ClusterInput.create!(
        block_height: height - 1,
        txid: "source-#{txid}-#{index}",
        vout: index,
        address: address,
        amount_btc: "1.00000000",
        spent: true,
        spent_txid: txid,
        spent_block_height: height,
        cluster_processed_at: marker
      )
    end
  end

  def capture_sql
    statements = []
    subscriber = lambda do |_name, _start, _finish, _id, payload|
      sql = payload[:sql].to_s
      statements << sql unless payload[:name] == "SCHEMA"
    end

    ActiveSupport::Notifications.subscribed(
      subscriber,
      "sql.active_record"
    ) { yield }
    statements
  end

  def assert_no_forbidden_sql(statements)
    cluster_input_writes = statements.grep(
      /\A\s*(?:UPDATE|INSERT\s+INTO|DELETE\s+FROM)\s+["`]?cluster_inputs\b/i
    )
    forbidden_reads = statements.grep(/\b(?:tx_outputs|utxo_outputs)\b/i)
    downstream_writes = statements.grep(
      /\A\s*(?:UPDATE|INSERT\s+INTO|DELETE\s+FROM)\s+["`]?(?:actor_profiles|actor_labels|actor_behavior_heavy_snapshots|cluster_activity_states)\b/i
    )

    assert_empty cluster_input_writes
    assert_empty forbidden_reads
    assert_empty downstream_writes
  end
end
