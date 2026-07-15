# frozen_string_literal: true

require "test_helper"

module ActorProfiles
  class StrictBuildFromClusterTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    def setup
      cleanup_records

      @height = 955_300
      @cluster = build_cluster(
        first_seen_height: @height - 10,
        last_seen_height: @height - 1
      )
      @address = create_address(@cluster, "core-builder")

      BlockBufferModel.create!(
        height: @height,
        block_hash: unique_hash("layer1"),
        status: "processed",
        processed_at: Time.current
      )

      @cluster_hash = unique_hash("cluster")
      ClusterProcessedBlock.create!(
        height: @height,
        block_hash: @cluster_hash,
        status: "processed",
        processed_at: Time.current
      )
      AddressSpendProjectionBlock.create!(
        height: @height,
        block_hash: @cluster_hash,
        status: "completed",
        completed_at: Time.current
      )
    end

    def teardown
      cleanup_records
    end

    test "builds strict core without tx_outputs rows" do
      assert_equal 0, TxOutput.count

      create_utxo(
        address: @address.address,
        amount_btc: "1.25",
        block_height: @height - 2
      )

      create_cluster_input(
        address: @address.address,
        amount_btc: "0.50",
        spent_txid: unique_txid("spend"),
        spent_block_height: @height - 1
      )

      result =
        ActorProfiles::StrictBuildFromCluster.call(
          cluster_id: @cluster.id
        )

      profile = ActorProfile.find(result.fetch(:profile_id))

      assert_equal "strict_v3_core", profile.traits["profile_version"]
      assert_equal true, profile.metadata["strict"]
      assert_equal "missing", profile.metadata["historical_enrichment_status"]
      assert_equal "addresses_cluster_inputs_utxo_outputs", profile.metadata["stats_source"]
      assert_equal BigDecimal("1.25"), profile.balance_btc
      assert_equal BigDecimal("0.50"), profile.total_sent_btc
      assert_nil profile.total_received_btc
      assert_nil profile.inflow_count
      assert_nil profile.traits["total_received_btc"]
      assert_nil profile.traits["received_outputs_count"]
    end

    test "does not query tx_outputs during strict core build" do
      create_utxo(
        address: @address.address,
        amount_btc: "2.00",
        block_height: @height - 3
      )

      queries = []

      callback =
        lambda do |_name, _started, _finished, _id, payload|
          sql = payload[:sql].to_s.downcase
          queries << sql if sql.include?("tx_outputs")
        end

      ActiveSupport::Notifications.subscribed(
        callback,
        "sql.active_record"
      ) do
        ActorProfiles::StrictBuildFromCluster.call(
          cluster_id: @cluster.id
        )
      end

      assert_empty queries
    end

    test "build works while tx_outputs projection is behind" do
      Layer1TxOutputProjectionBlock.create!(
        height: @height - 1,
        block_hash: unique_hash("projection"),
        status: "pending",
        expected_outputs_count: 1,
        expected_outputs_value_btc: "1.0"
      )

      create_utxo(
        address: @address.address,
        amount_btc: "3.00",
        block_height: @height - 1
      )

      result =
        ActorProfiles::StrictBuildFromCluster.call(
          cluster_id: @cluster.id
        )

      assert_equal true, result[:ok]
      assert_equal "strict_v3_core", ActorProfile.find(result[:profile_id]).traits["profile_version"]
    end

    test "strict core uses utxo_outputs for balance and cluster_inputs for spending" do
      create_utxo(
        address: @address.address,
        amount_btc: "4.25",
        block_height: @height - 5
      )

      2.times do |index|
        create_cluster_input(
          address: @address.address,
          amount_btc: "0.75",
          spent_txid: unique_txid("spent-#{index}"),
          spent_block_height: @height - index - 1
        )
      end

      ActorProfiles::StrictBuildFromCluster.call(
        cluster_id: @cluster.id
      )

      profile = @cluster.reload.actor_profile

      assert_equal BigDecimal("4.25"), profile.balance_btc
      assert_equal BigDecimal("1.50"), profile.total_sent_btc
      assert_equal 2, profile.outflow_count
      assert_equal 2, profile.tx_count
      assert_equal 2, profile.traits["spent_tx_count"]
      assert_equal 2, profile.traits["spent_inputs_count"]
      assert_equal 1, profile.traits["live_utxo_count"]
    end

    test "tx_count counts distinct spent transactions" do
      spent_txid = unique_txid("shared-spend")

      2.times do
        create_cluster_input(
          address: @address.address,
          amount_btc: "0.25",
          spent_txid: spent_txid,
          spent_block_height: @height - 1
        )
      end

      ActorProfiles::StrictBuildFromCluster.call(
        cluster_id: @cluster.id
      )

      profile = @cluster.reload.actor_profile

      assert_equal 1, profile.tx_count
      assert_equal 1, profile.traits["spent_tx_count"]
      assert_equal 2, profile.outflow_count
      assert_equal 2, profile.traits["spent_inputs_count"]
    end

    test "rebuild clears old historical values" do
      ActorProfile.create!(
        cluster: @cluster,
        balance_btc: "9.0",
        total_received_btc: "123.45",
        total_sent_btc: "88.00",
        net_btc: "9.0",
        tx_count: 99,
        inflow_count: 77,
        outflow_count: 66,
        accumulation_score: 100,
        distribution_score: 100,
        etf_score: 100,
        traits: {
          "profile_version" => "strict_v2",
          "total_received_btc" => "123.45",
          "received_outputs_count" => 77
        },
        metadata: {
          "strict" => true,
          "profile_version" => "strict_v2"
        },
        last_computed_height: @height - 1,
        cluster_composition_version: @cluster.composition_version
      )

      create_utxo(
        address: @address.address,
        amount_btc: "5.00",
        block_height: @height - 1
      )

      ActorProfiles::StrictBuildFromCluster.call(
        cluster_id: @cluster.id
      )

      profile = @cluster.reload.actor_profile

      assert_nil profile.total_received_btc
      assert_nil profile.inflow_count
      assert_nil profile.accumulation_score
      assert_nil profile.distribution_score
      assert_nil profile.etf_score
      assert_nil profile.traits["total_received_btc"]
      assert_nil profile.traits["received_outputs_count"]
      assert_equal "missing", profile.metadata["historical_enrichment_status"]
    end

    test "build is idempotent" do
      create_utxo(
        address: @address.address,
        amount_btc: "1.00",
        block_height: @height - 1
      )

      first =
        ActorProfiles::StrictBuildFromCluster.call(
          cluster_id: @cluster.id
        )

      second =
        ActorProfiles::StrictBuildFromCluster.call(
          cluster_id: @cluster.id
        )

      assert_equal first[:profile_id], second[:profile_id]
      assert_equal 1, ActorProfile.where(cluster_id: @cluster.id).count
      assert_equal BigDecimal("1.00"), @cluster.reload.actor_profile.balance_btc
    end

    private

    def build_cluster(first_seen_height:, last_seen_height:)
      Cluster.create!(
        address_count: 1,
        first_seen_height: first_seen_height,
        last_seen_height: last_seen_height,
        composition_version: 1
      )
    end

    def create_address(cluster, prefix)
      Address.create!(
        address: "#{prefix}-#{SecureRandom.hex(8)}",
        cluster: cluster
      )
    end

    def create_utxo(address:, amount_btc:, block_height:)
      UtxoOutput.create!(
        txid: unique_txid("utxo"),
        vout: 0,
        address: address,
        amount_btc: amount_btc,
        block_height: block_height,
        block_hash: unique_hash("utxo")
      )
    end

    def create_cluster_input(
      address:,
      amount_btc:,
      spent_txid:,
      spent_block_height:
    )
      ClusterInput.create!(
        block_height: spent_block_height - 1,
        txid: unique_txid("input"),
        vout: 0,
        address: address,
        amount_btc: amount_btc,
        spent: true,
        spent_txid: spent_txid,
        spent_block_height: spent_block_height
      )
    end

    def unique_txid(prefix)
      Digest::SHA256.hexdigest(
        "#{prefix}-#{SecureRandom.hex(16)}"
      )
    end

    def unique_hash(prefix)
      Digest::SHA256.hexdigest(
        "#{prefix}-#{SecureRandom.hex(16)}"
      )
    end

    def cleanup_records
      ActorLabel.delete_all
      ActorProfile.delete_all
      AddressSpendStat.delete_all
      AddressSpendProjectionBlock.delete_all
      Layer1TxOutputProjectionBlock.delete_all
      ClusterInput.delete_all
      UtxoOutput.delete_all
      TxOutput.delete_all
      Address.delete_all
      ClusterProcessedBlock.delete_all
      BlockBufferModel.delete_all
      Cluster.delete_all
    end
  end
end
