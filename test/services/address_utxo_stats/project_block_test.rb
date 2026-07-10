# frozen_string_literal: true

require "test_helper"

module AddressUtxoStats
  class ProjectBlockTest < ActiveSupport::TestCase
    BASE_HEIGHT =
      1_700_000

    FakeClusterCheckpoint =
      Struct.new(
        :height,
        :block_hash,
        :status,
        keyword_init: true
      )

    setup do
      @cluster_checkpoints =
        {}
    end

    test "projects a valid receive-only block" do
      height =
        BASE_HEIGHT + 1

      build_processed_block(
        height: height
      )

      create_utxo(
        height: height,
        txid: "receive-only",
        address: address("receive-only"),
        amount_btc: "1.25"
      )

      result =
        project_block(
          height: height
        )

      stat =
        AddressUtxoStat.find_by!(
          address: address("receive-only")
        )

      assert result[:ok]
      assert_equal "completed", result[:status]
      assert_not result[:idempotent]
      assert_equal 125_000_000, stat.total_received_sats
      assert_equal 125_000_000, stat.current_balance_sats
      assert_equal 1, stat.live_utxo_count
      assert_equal 1, stat.received_output_count
      assert_equal height, stat.first_received_height
      assert_equal height, stat.last_received_height
      assert_equal height, stat.last_changed_height
    end

    test "applies a spend to an existing address" do
      height =
        BASE_HEIGHT + 2

      raw_address =
        address("existing-spend")

      AddressUtxoStat.create!(
        address: raw_address,
        total_received_sats: 200,
        current_balance_sats: 150,
        live_utxo_count: 2,
        received_output_count: 2,
        first_received_height: height - 10,
        last_received_height: height - 5,
        last_changed_height: height - 5,
        projection_version: AddressUtxoStat::PROJECTION_VERSION
      )

      build_processed_block(
        height: height
      )

      create_input(
        creation_height: height - 10,
        spent_height: height,
        txid: "spent-existing",
        address: raw_address,
        amount_btc: "0.00000100"
      )

      result =
        project_block(
          height: height
        )

      stat =
        AddressUtxoStat.find_by!(
          address: raw_address
        )

      assert result[:ok]
      assert_equal 200, stat.total_received_sats
      assert_equal 50, stat.current_balance_sats
      assert_equal 1, stat.live_utxo_count
      assert_equal 2, stat.received_output_count
      assert_equal height, stat.last_changed_height

      checkpoint =
        AddressUtxoProjectionBlock.find_by!(
          height: height
        )

      assert_predicate checkpoint, :completed?
    end

    test "handles an output created and spent in the same block" do
      height =
        BASE_HEIGHT + 3

      raw_address =
        address("same-block")

      build_processed_block(
        height: height
      )

      create_input(
        creation_height: height,
        spent_height: height,
        txid: "same-block",
        address: raw_address,
        amount_btc: "0.00000100"
      )

      result =
        project_block(
          height: height
        )

      stat =
        AddressUtxoStat.find_by!(
          address: raw_address
        )

      assert result[:ok]
      assert_equal 100, stat.total_received_sats
      assert_equal 0, stat.current_balance_sats
      assert_equal 0, stat.live_utxo_count
      assert_equal 1, stat.received_output_count
      assert_equal height, stat.first_received_height
      assert_equal height, stat.last_received_height
    end

    test "rejects a spend for an absent address" do
      height =
        BASE_HEIGHT + 18

      raw_address =
        address("absent-spend")

      build_processed_block(
        height: height
      )

      builder =
        FakeBuilder.new(
          delta_result(
            height: height,
            deltas: [
              spend_delta(
                address: raw_address,
                height: height,
                sats: 1
              )
            ]
          )
        )

      result =
        project_block(
          height: height,
          block_delta_builder: builder
        )

      checkpoint =
        AddressUtxoProjectionBlock.find_by!(
          height: height
        )

      assert_not result[:ok]
      assert_equal "failed", result[:status]
      assert_equal(
        "final_state_invalid",
        result[:error][:code]
      )
      assert_not checkpoint.completed?
      assert_not AddressUtxoStat.exists?(
        address: raw_address
      )
    end

    test "applies several addresses atomically" do
      height =
        BASE_HEIGHT + 4

      build_processed_block(
        height: height
      )

      create_utxo(
        height: height,
        txid: "atomic-a",
        address: address("atomic-a"),
        amount_btc: "0.00000001"
      )

      create_utxo(
        height: height,
        txid: "atomic-b",
        address: address("atomic-b"),
        amount_btc: "0.00000002"
      )

      result =
        project_block(
          height: height
        )

      assert_equal 2, result[:addresses_written]
      assert_equal 2, AddressUtxoStat.where(
        address: [
          address("atomic-a"),
          address("atomic-b")
        ]
      ).count
    end

    test "replaying the same completed height and hash is idempotent" do
      height =
        BASE_HEIGHT + 5

      raw_address =
        address("replay")

      build_processed_block(
        height: height
      )

      create_utxo(
        height: height,
        txid: "replay",
        address: raw_address,
        amount_btc: "0.00000010"
      )

      first =
        project_block(
          height: height
        )

      second =
        project_block(
          height: height
        )

      stat =
        AddressUtxoStat.find_by!(
          address: raw_address
        )

      assert_equal "completed", first[:status]
      assert_equal "already_completed", second[:status]
      assert second[:idempotent]
      assert_equal 10, stat.total_received_sats
      assert_equal 1, second[:attempts]
      assert_equal 0, second[:addresses_written]
    end

    test "rejects same height with a different hash" do
      height =
        BASE_HEIGHT + 6

      build_processed_block(
        height: height,
        block_hash: "cluster-new-hash"
      )

      AddressUtxoProjectionBlock.create!(
        height: height,
        block_hash: "old-hash",
        status: "completed",
        completed_at: Time.current
      )

      result =
        project_block(
          height: height
        )

      checkpoint =
        AddressUtxoProjectionBlock.find_by!(
          height: height
        )

      assert_not result[:ok]
      assert_equal "blocked", result[:status]
      assert_equal "block_hash_mismatch", result[:error][:code]
      assert_equal "old-hash", checkpoint.block_hash
      assert_predicate checkpoint, :completed?
    end

    test "rejects absent or non processed Cluster checkpoints" do
      absent_height =
        BASE_HEIGHT + 7

      absent_result =
        project_block(
          height: absent_height
        )

      assert_not absent_result[:ok]
      assert_equal "blocked", absent_result[:status]
      assert_equal(
        "cluster_checkpoint_unavailable",
        absent_result[:error][:code]
      )
      assert_not AddressUtxoProjectionBlock.exists?(
        height: absent_height
      )

      pending_height =
        BASE_HEIGHT + 8

      build_processed_block(
        height: pending_height,
        status: "processing"
      )

      pending_result =
        project_block(
          height: pending_height
        )

      assert_not pending_result[:ok]
      assert_equal(
        "cluster_checkpoint_not_processed",
        pending_result[:error][:code]
      )
      assert_not AddressUtxoProjectionBlock.exists?(
        height: pending_height
      )
    end

    test "default resolver returns unavailable when Cluster checkpoint model is absent" do
      height =
        BASE_HEIGHT + 17

      previous_constant =
        if Object.const_defined?(:ClusterProcessedBlock, false)
          Object.const_get(
            :ClusterProcessedBlock
          )
        end

      Object.send(
        :remove_const,
        :ClusterProcessedBlock
      ) if previous_constant

      result =
        ProjectBlock.call(
          height: height
        )

      assert_not result[:ok]
      assert_equal "blocked", result[:status]
      assert_equal(
        "cluster_checkpoint_unavailable",
        result[:error][:code]
      )
      assert_not AddressUtxoProjectionBlock.completed.exists?(
        height: height
      )
      assert_not AddressUtxoStat.exists?(
        address: address("default-missing")
      )
    ensure
      if previous_constant &&
         !Object.const_defined?(:ClusterProcessedBlock, false)
        Object.const_set(
          :ClusterProcessedBlock,
          previous_constant
        )
      end
    end

    test "delta anomalies prevent address persistence and completion" do
      height =
        BASE_HEIGHT + 9

      build_processed_block(
        height: height
      )

      builder =
        FakeBuilder.new(
          delta_result(
            height: height,
            anomalies: [
              {
                type: :output_contradiction
              }
            ],
            deltas: [
              received_delta(
                address: address("anomaly"),
                height: height,
                sats: 10
              )
            ]
          )
        )

      result =
        project_block(
          height: height,
          block_delta_builder: builder
        )

      checkpoint =
        AddressUtxoProjectionBlock.find_by!(
          height: height
        )

      assert_not result[:ok]
      assert_equal "blocked", result[:status]
      assert_equal(
        "delta_anomalies_detected",
        result[:error][:code]
      )
      assert_equal "failed", checkpoint.status
      assert_not AddressUtxoStat.exists?(
        address: address("anomaly")
      )
    end

    test "upsert errors rollback every address delta" do
      height =
        BASE_HEIGHT + 10

      build_processed_block(
        height: height
      )

      builder =
        FakeBuilder.new(
          delta_result(
            height: height,
            deltas: [
              received_delta(
                address: address("rollback-valid"),
                height: height,
                sats: 10
              ),
              spend_delta(
                address: address("rollback-invalid"),
                height: height,
                sats: 1
              )
            ]
          )
        )

      result =
        project_block(
          height: height,
          block_delta_builder: builder
        )

      assert_not result[:ok]
      assert_equal "failed", result[:status]
      assert_equal(
        "final_state_invalid",
        result[:error][:code]
      )
      assert_not AddressUtxoStat.exists?(
        address: address("rollback-valid")
      )
      assert_not AddressUtxoStat.exists?(
        address: address("rollback-invalid")
      )

      checkpoint =
        AddressUtxoProjectionBlock.find_by!(
          height: height
        )

      assert_equal "failed", checkpoint.status
    end

    test "negative final counters rollback" do
      height =
        BASE_HEIGHT + 11

      raw_address =
        address("negative-counter")

      build_processed_block(
        height: height
      )

      AddressUtxoStat.create!(
        address: raw_address,
        total_received_sats: 10,
        current_balance_sats: 10,
        live_utxo_count: 0,
        received_output_count: 1,
        first_received_height: height - 1,
        last_received_height: height - 1,
        last_changed_height: height - 1,
        projection_version: AddressUtxoStat::PROJECTION_VERSION
      )

      builder =
        FakeBuilder.new(
          delta_result(
            height: height,
            deltas: [
              {
                address: raw_address,
                received_sats_delta: 0,
                spent_sats_delta: 0,
                balance_sats_delta: 0,
                live_utxo_count_delta: -1,
                received_output_count_delta: 0,
                first_received_height_candidate: nil,
                last_received_height_candidate: nil,
                last_changed_height: height
              }
            ],
            total_spent_sats: 0,
            balance_delta_sats: 0
          )
        )

      result =
        project_block(
          height: height,
          block_delta_builder: builder
        )

      stat =
        AddressUtxoStat.find_by!(
          address: raw_address
        )

      assert_not result[:ok]
      assert_equal "failed", result[:status]
      assert_equal 0, stat.live_utxo_count
      assert_equal height - 1, stat.last_changed_height
    end

    test "increments attempts on a controlled retry" do
      height =
        BASE_HEIGHT + 12

      build_processed_block(
        height: height,
        block_hash: "retry-hash"
      )

      AddressUtxoProjectionBlock.create!(
        height: height,
        block_hash: "retry-hash",
        status: "failed",
        attempts: 1
      )

      create_utxo(
        height: height,
        txid: "retry",
        address: address("retry"),
        amount_btc: "0.00000003"
      )

      result =
        project_block(
          height: height
        )

      assert result[:ok]
      assert_equal "completed", result[:status]
      assert_equal 2, result[:attempts]
      assert_equal 3, AddressUtxoStat.find_by!(
        address: address("retry")
      ).total_received_sats
    end

    test "completed checkpoint stores all counters" do
      height =
        BASE_HEIGHT + 13

      build_processed_block(
        height: height
      )

      create_utxo(
        height: height,
        txid: "checkpoint-received",
        address: address("checkpoint-received"),
        amount_btc: "0.00000010"
      )

      create_input(
        creation_height: height,
        spent_height: height,
        txid: "checkpoint-roundtrip",
        address: address("checkpoint-roundtrip"),
        amount_btc: "0.00000004"
      )

      result =
        project_block(
          height: height
        )

      checkpoint =
        AddressUtxoProjectionBlock.find_by!(
          height: height
        )

      assert result[:ok]
      assert_predicate checkpoint, :completed?
      assert_equal 2, checkpoint.received_output_count
      assert_equal 1, checkpoint.spent_output_count
      assert_equal 2, checkpoint.received_address_count
      assert_equal 1, checkpoint.spent_address_count
      assert_equal 14, checkpoint.total_received_sats
      assert_equal 4, checkpoint.total_spent_sats
      assert_equal(
        "strict_v1_block_delta_builder",
        checkpoint.metadata.fetch(
          "block_delta_builder_version"
        )
      )
      assert_equal 2, checkpoint.metadata.fetch("addresses_touched")
      assert_equal 10, checkpoint.metadata.fetch("balance_delta_sats")
    end

    test "uses an advisory lock per projected height" do
      height =
        BASE_HEIGHT + 14

      build_processed_block(
        height: height
      )

      create_utxo(
        height: height,
        txid: "lock",
        address: address("lock"),
        amount_btc: "0.00000001"
      )

      lock_manager =
        RecordingLock.new

      first =
        project_block(
          height: height,
          lock_manager: lock_manager
        )

      second =
        project_block(
          height: height,
          lock_manager: lock_manager
        )

      assert_equal "completed", first[:status]
      assert_equal "already_completed", second[:status]
      assert_equal [height, height], lock_manager.heights
    end

    test "does not depend on tx_outputs" do
      service_source =
        Rails.root.join(
          "app/services/address_utxo_stats/project_block.rb"
        ).read

      assert_not_includes service_source, "tx_outputs"
    end

    test "returns deterministic counters for equivalent inputs" do
      first_height =
        BASE_HEIGHT + 15

      second_height =
        BASE_HEIGHT + 16

      build_processed_block(
        height: first_height
      )

      build_processed_block(
        height: second_height
      )

      first_builder =
        FakeBuilder.new(
          delta_result(
            height: first_height,
            deltas: [
              received_delta(
                address: address("det-a"),
                height: first_height,
                sats: 2
              ),
              received_delta(
                address: address("det-b"),
                height: first_height,
                sats: 3
              )
            ]
          )
        )

      second_builder =
        FakeBuilder.new(
          delta_result(
            height: second_height,
            deltas: [
              received_delta(
                address: address("det-b2"),
                height: second_height,
                sats: 3
              ),
              received_delta(
                address: address("det-a2"),
                height: second_height,
                sats: 2
              )
            ]
          )
        )

      first =
        project_block(
          height: first_height,
          block_delta_builder: first_builder
        )

      second =
        project_block(
          height: second_height,
          block_delta_builder: second_builder
        )

      assert_equal(
        deterministic_projection_fields(first),
        deterministic_projection_fields(second)
      )
    end

    private

    class FakeBuilder
      def initialize(result)
        @result =
          result
      end

      def call(**_attributes)
        @result
      end
    end

    class RecordingLock
      attr_reader :heights

      def initialize
        @heights =
          []
      end

      def call(height:, connection:)
        heights << height

        connection.execute(
          "SELECT 1"
        )
      end
    end

    def project_block(**attributes)
      ProjectBlock.call(
        **attributes,
        cluster_checkpoint_resolver:
          lambda do |height:|
            @cluster_checkpoints[height]
          end
      )
    end

    def build_processed_block(
      height:,
      block_hash: nil,
      status: "processed"
    )
      checkpoint =
        FakeClusterCheckpoint.new(
        height: height,
        block_hash:
          block_hash ||
          "block-hash-#{height}",
        status: status
      )

      @cluster_checkpoints[height] =
        checkpoint

      checkpoint
    end

    def create_utxo(
      height:,
      txid:,
      address:,
      amount_btc:,
      vout: 0
    )
      UtxoOutput.create!(
        txid: txid,
        vout: vout,
        address: address,
        amount_btc: BigDecimal(amount_btc),
        block_height: height,
        block_hash: "block-hash-#{height}"
      )
    end

    def create_input(
      creation_height:,
      spent_height:,
      txid:,
      address:,
      amount_btc:,
      vout: 0
    )
      ClusterInput.create!(
        block_height: creation_height,
        txid: txid,
        vout: vout,
        address: address,
        amount_btc: BigDecimal(amount_btc),
        spent: true,
        spent_txid: "spent-#{txid}",
        spent_block_height: spent_height
      )
    end

    def address(suffix)
      "bc1qaddressutxoproject#{suffix}" \
        "000000000000000000000000"
    end

    def delta_result(
      height:,
      deltas: [],
      anomalies: [],
      total_spent_sats: nil,
      balance_delta_sats: nil
    )
      total_received_sats =
        deltas.sum do |delta|
          delta.fetch(:received_sats_delta)
        end

      computed_total_spent_sats =
        deltas.sum do |delta|
          delta.fetch(:spent_sats_delta)
        end

      computed_balance_delta_sats =
        deltas.sum do |delta|
          delta.fetch(:balance_sats_delta)
        end

      received_deltas =
        deltas.select do |delta|
          delta.fetch(:received_output_count_delta).positive?
        end

      spent_deltas =
        deltas.select do |delta|
          delta.fetch(:spent_sats_delta).positive? ||
            delta.fetch(:live_utxo_count_delta).negative?
        end

      {
        height: height,
        block_hash: "block-hash-#{height}",
        addresses_touched: deltas.size,
        received_output_count:
          received_deltas.sum do |delta|
            delta.fetch(:received_output_count_delta)
          end,
        spent_output_count: spent_deltas.size,
        received_address_count:
          received_deltas.map { |delta| delta.fetch(:address) }.uniq.size,
        spent_address_count:
          spent_deltas.map { |delta| delta.fetch(:address) }.uniq.size,
        total_received_sats: total_received_sats,
        total_spent_sats:
          total_spent_sats || computed_total_spent_sats,
        balance_delta_sats:
          balance_delta_sats || computed_balance_delta_sats,
        deltas: deltas,
        anomalies: anomalies
      }
    end

    def received_delta(address:, height:, sats:)
      {
        address: address,
        received_sats_delta: sats,
        spent_sats_delta: 0,
        balance_sats_delta: sats,
        live_utxo_count_delta: 1,
        received_output_count_delta: 1,
        first_received_height_candidate: height,
        last_received_height_candidate: height,
        last_changed_height: height
      }
    end

    def spend_delta(address:, height:, sats:)
      {
        address: address,
        received_sats_delta: 0,
        spent_sats_delta: sats,
        balance_sats_delta: -sats,
        live_utxo_count_delta: -1,
        received_output_count_delta: 0,
        first_received_height_candidate: nil,
        last_received_height_candidate: nil,
        last_changed_height: height
      }
    end

    def deterministic_projection_fields(result)
      result.slice(
        :ok,
        :status,
        :idempotent,
        :received_output_count,
        :spent_output_count,
        :received_address_count,
        :spent_address_count,
        :total_received_sats,
        :total_spent_sats,
        :addresses_written
      )
    end
  end
end
