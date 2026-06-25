# frozen_string_literal: true

require "test_helper"

module Clusters
  module Coverage
    class IncrementalTest < ActiveSupport::TestCase
      VALID_ADDRESS =
        "1BoatSLRHtKNngkdXEeobR76b53LETtpyT"

      SECOND_VALID_ADDRESS =
        "3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy"

      INVALID_ADDRESS =
        "not-a-bitcoin-address"

      def setup
        cleanup_records
        @height = 955_500
        @block_hash = unique_hash("block")
      end

      def teardown
        cleanup_records
      end

      test "defers when cluster block is not certified without checkpoint write" do
        create_projection(
          status: "projected",
          expected_outputs_count: 0,
          projected_outputs_count: 0
        )

        assert_no_difference -> { ClusterCoverageBlock.count } do
          result =
            Clusters::Coverage::PrepareBlock.call(
              height: @height
            )

          assert_equal true, result[:ok]
          assert_equal true, result[:deferred]
          assert_equal "cluster_block_not_processed", result[:reason]
        end
      end

      test "defers when tx output projection is not projected" do
        create_cluster_block
        create_projection(
          status: "pending",
          expected_outputs_count: 1,
          projected_outputs_count: 0
        )

        assert_no_difference -> { Address.count } do
          assert_no_difference -> { Cluster.count } do
            result =
              Clusters::Coverage::PrepareBlock.call(
                height: @height
              )

            assert_equal true, result[:ok]
            assert_equal true, result[:deferred]
            assert_equal "tx_output_projection_not_projected", result[:reason]
          end
        end

        coverage =
          ClusterCoverageBlock.find_by!(height: @height)

        assert_equal "deferred", coverage.status
        assert_nil coverage.after_tx_output_id
      end

      test "fails explicitly on block hash mismatch without advancing checkpoint" do
        create_cluster_block
        create_projection(
          block_hash: unique_hash("projection"),
          status: "projected",
          expected_outputs_count: 0,
          projected_outputs_count: 0
        )

        result =
          Clusters::Coverage::PrepareBlock.call(
            height: @height
          )

        assert_equal false, result[:ok]
        assert_equal true, result[:failed]
        assert_equal "projection_block_hash_mismatch", result[:reason]

        coverage =
          ClusterCoverageBlock.find_by!(height: @height)

        assert_equal "failed", coverage.status
        assert_nil coverage.after_tx_output_id
      end

      test "skips a completed coverage block without writing" do
        create_cluster_block
        create_projection(
          status: "projected",
          expected_outputs_count: 0,
          projected_outputs_count: 0
        )

        coverage =
          ClusterCoverageBlock.create!(
            height: @height,
            block_hash: @block_hash,
            status: "completed",
            expected_outputs_count: 0,
            processed_outputs_count: 0,
            expected_address_outputs_count: 0,
            processed_address_outputs_count: 0
          )

        assert_no_difference -> { Address.count } do
          result =
            Clusters::Coverage::ProcessPage.call(
              height: @height
            )

          assert_equal true, result[:ok]
          assert_equal true, result[:already_completed]
        end

        assert_equal coverage.updated_at.to_i, coverage.reload.updated_at.to_i
      end

      test "selects cluster processed blocks in ascending order" do
        create_cluster_block(height: @height + 1)
        create_projection(
          height: @height + 1,
          status: "projected",
          expected_outputs_count: 0,
          projected_outputs_count: 0
        )

        create_cluster_block(height: @height)
        create_projection(
          height: @height,
          status: "projected",
          expected_outputs_count: 0,
          projected_outputs_count: 0
        )

        result =
          Clusters::Coverage::PrepareBlock.call

        assert_equal true, result[:prepared]
        assert_equal @height, result[:height]
      end

      test "automatic selection skips old blocks without projection and pending projections" do
        old_height =
          @height - 2

        pending_height =
          @height - 1

        projected_height =
          @height

        old_hash =
          unique_hash("old")

        pending_hash =
          unique_hash("pending")

        projected_hash =
          unique_hash("projected")

        create_cluster_block(
          height: old_height,
          block_hash: old_hash
        )

        create_cluster_block(
          height: pending_height,
          block_hash: pending_hash
        )

        create_projection(
          height: pending_height,
          block_hash: pending_hash,
          status: "pending",
          expected_outputs_count: 1,
          projected_outputs_count: 0
        )

        create_cluster_block(
          height: projected_height,
          block_hash: projected_hash
        )

        create_projection(
          height: projected_height,
          block_hash: projected_hash,
          status: "projected",
          expected_outputs_count: 0,
          projected_outputs_count: 0
        )

        result =
          Clusters::Coverage::PrepareBlock.call

        assert_equal true, result[:prepared]
        assert_equal projected_height, result[:height]
        assert_nil ClusterCoverageBlock.find_by(height: old_height)
        assert_nil ClusterCoverageBlock.find_by(height: pending_height)
      end

      test "automatic selection chooses a newer projected block when an older block has no projection" do
        old_height =
          @height

        newer_height =
          @height + 1

        newer_hash =
          unique_hash("newer")

        create_cluster_block(
          height: old_height,
          block_hash: unique_hash("old")
        )

        create_cluster_block(
          height: newer_height,
          block_hash: newer_hash
        )

        create_projection(
          height: newer_height,
          block_hash: newer_hash,
          status: "projected",
          expected_outputs_count: 0,
          projected_outputs_count: 0
        )

        result =
          Clusters::Coverage::PrepareBlock.call

        assert_equal true, result[:prepared]
        assert_equal newer_height, result[:height]
        assert_nil ClusterCoverageBlock.find_by(height: old_height)
      end

      test "automatic selection ignores pending projection without writing a deferred checkpoint" do
        create_cluster_block
        create_projection(
          status: "pending",
          expected_outputs_count: 1,
          projected_outputs_count: 0
        )

        assert_no_difference -> { ClusterCoverageBlock.count } do
          result =
            Clusters::Coverage::PrepareBlock.call

          assert_equal true, result[:ok]
          assert_equal false, result[:prepared]
          assert_equal true, result[:deferred]
          assert_equal "no_eligible_projected_cluster_block", result[:reason]
        end
      end

      test "baseline excludes blocks at or below incremental start height" do
        create_bootstrap_baseline(
          incremental_start_height: @height
        )

        next_height =
          @height + 1

        next_hash =
          unique_hash("next")

        create_cluster_block
        create_projection(
          status: "projected",
          expected_outputs_count: 0,
          projected_outputs_count: 0
        )

        create_cluster_block(
          height: next_height,
          block_hash: next_hash
        )

        create_projection(
          height: next_height,
          block_hash: next_hash,
          status: "projected",
          expected_outputs_count: 0,
          projected_outputs_count: 0
        )

        result =
          Clusters::Coverage::PrepareBlock.call

        assert_equal true, result[:prepared]
        assert_equal next_height, result[:height]
      end

      test "first block after baseline is selected only when projected" do
        create_bootstrap_baseline(
          incremental_start_height: @height
        )

        pending_height =
          @height + 1

        projected_height =
          @height + 2

        pending_hash =
          unique_hash("pending")

        projected_hash =
          unique_hash("projected")

        create_cluster_block(
          height: pending_height,
          block_hash: pending_hash
        )

        create_projection(
          height: pending_height,
          block_hash: pending_hash,
          status: "pending",
          expected_outputs_count: 1,
          projected_outputs_count: 0
        )

        create_cluster_block(
          height: projected_height,
          block_hash: projected_hash
        )

        create_projection(
          height: projected_height,
          block_hash: projected_hash,
          status: "projected",
          expected_outputs_count: 0,
          projected_outputs_count: 0
        )

        result =
          Clusters::Coverage::PrepareBlock.call

        assert_equal true, result[:prepared]
        assert_equal projected_height, result[:height]
        assert_nil ClusterCoverageBlock.find_by(height: pending_height)
      end

      test "automatic selection does not reprocess completed blocks" do
        create_cluster_block
        create_projection(
          status: "projected",
          expected_outputs_count: 0,
          projected_outputs_count: 0
        )

        ClusterCoverageBlock.create!(
          height: @height,
          block_hash: @block_hash,
          status: "completed",
          expected_outputs_count: 0,
          processed_outputs_count: 0,
          expected_address_outputs_count: 0,
          processed_address_outputs_count: 0
        )

        next_height =
          @height + 1

        next_hash =
          unique_hash("next")

        create_cluster_block(
          height: next_height,
          block_hash: next_hash
        )

        create_projection(
          height: next_height,
          block_hash: next_hash,
          status: "projected",
          expected_outputs_count: 0,
          projected_outputs_count: 0
        )

        result =
          Clusters::Coverage::PrepareBlock.call

        assert_equal true, result[:prepared]
        assert_equal next_height, result[:height]
      end

      test "automatic selection skips block hash mismatches without failing the pipeline" do
        mismatched_height =
          @height

        next_height =
          @height + 1

        next_hash =
          unique_hash("next")

        create_cluster_block(
          height: mismatched_height,
          block_hash: unique_hash("cluster")
        )

        create_projection(
          height: mismatched_height,
          block_hash: unique_hash("projection"),
          status: "projected",
          expected_outputs_count: 0,
          projected_outputs_count: 0
        )

        create_cluster_block(
          height: next_height,
          block_hash: next_hash
        )

        create_projection(
          height: next_height,
          block_hash: next_hash,
          status: "projected",
          expected_outputs_count: 0,
          projected_outputs_count: 0
        )

        result =
          Clusters::Coverage::PrepareBlock.call

        assert_equal true, result[:prepared]
        assert_equal next_height, result[:height]
        assert_nil ClusterCoverageBlock.find_by(height: mismatched_height)
      end

      test "automatic preparation does not create actor state or bootstrap checkpoint" do
        create_cluster_block
        create_projection(
          status: "projected",
          expected_outputs_count: 0,
          projected_outputs_count: 0
        )

        assert_no_difference -> { ActorProfile.count } do
          assert_no_difference -> { ActorLabel.count } do
            Clusters::Coverage::PrepareBlock.call
          end
        end

        assert_equal 0,
          ClusterCoverageBlock
            .where("metadata ->> 'mode' = ?", "bootstrap")
            .count
      end

      test "creates a singleton for a new valid address" do
        prepare_projected_block(
          [VALID_ADDRESS]
        )

        assert_no_difference -> { AddressLink.count } do
          assert_difference -> { Address.count }, 1 do
            assert_difference -> { Cluster.count }, 1 do
              process_without_actor_profile_dirty
            end
          end
        end

        address =
          Address.find_by!(address: VALID_ADDRESS)

        cluster =
          Cluster.find(address.cluster_id)

        assert_equal 1, cluster.composition_version
        assert_equal 1, Address.where(cluster_id: cluster.id).count
        assert_equal 1, cluster.address_count
      end

      test "assigns singleton to an existing unclustered address" do
        Address.create!(
          address: VALID_ADDRESS
        )

        prepare_projected_block(
          [VALID_ADDRESS]
        )

        assert_no_difference -> { Address.count } do
          assert_difference -> { Cluster.count }, 1 do
            process_without_actor_profile_dirty
          end
        end

        assert Address.find_by!(address: VALID_ADDRESS).cluster_id.present?
      end

      test "does not move an already clustered address" do
        cluster =
          Cluster.create!(
            composition_version: 9,
            address_count: 1
          )

        address =
          Address.create!(
            address: VALID_ADDRESS,
            cluster: cluster
          )

        prepare_projected_block(
          [VALID_ADDRESS]
        )

        assert_no_difference -> { Cluster.count } do
          process_without_actor_profile_dirty
        end

        assert_equal cluster.id, address.reload.cluster_id
        assert_equal 9, cluster.reload.composition_version
      end

      test "multiple outputs to the same address create one singleton only" do
        prepare_projected_block(
          [
            VALID_ADDRESS,
            VALID_ADDRESS
          ]
        )

        assert_difference -> { Cluster.count }, 1 do
          process_without_actor_profile_dirty
        end

        address =
          Address.find_by!(address: VALID_ADDRESS)

        assert_equal 1, Address.where(cluster_id: address.cluster_id).count
      end

      test "replaying a completed block is idempotent" do
        prepare_projected_block(
          [VALID_ADDRESS]
        )

        process_without_actor_profile_dirty

        cluster_id =
          Address.find_by!(address: VALID_ADDRESS).cluster_id

        assert_no_difference -> { Cluster.count } do
          result =
            Clusters::Coverage::ProcessPage.call(
              height: @height
            )

          assert_equal true, result[:already_completed]
        end

        assert_equal cluster_id, Address.find_by!(address: VALID_ADDRESS).cluster_id
      end

      test "blank and invalid output addresses do not create singletons" do
        prepare_projected_block(
          [
            nil,
            "",
            INVALID_ADDRESS
          ]
        )

        assert_no_difference -> { Address.count } do
          assert_no_difference -> { Cluster.count } do
            process_without_actor_profile_dirty
          end
        end

        coverage =
          ClusterCoverageBlock.find_by!(height: @height)

        assert_equal "completed", coverage.status
        assert_equal 3, coverage.processed_outputs_count
        assert_equal 0, coverage.processed_address_outputs_count
        assert_equal 2, coverage.scripts_without_address_count
        assert_equal 1, coverage.metadata["expected_invalid_address_outputs_count"]
      end

      test "resumes from the exact cursor after a partial page" do
        prepare_projected_block(
          [
            VALID_ADDRESS,
            SECOND_VALID_ADDRESS,
            valid_bech32_address
          ]
        )

        first =
          process_without_actor_profile_dirty(batch_size: 2)

        coverage =
          ClusterCoverageBlock.find_by!(height: @height)

        assert_equal "processing", coverage.status
        assert_equal 2, coverage.processed_outputs_count
        assert_equal first[:after_tx_output_id], coverage.after_tx_output_id
        assert_equal 1, coverage.pages_processed

        second =
          process_without_actor_profile_dirty(batch_size: 2)

        coverage.reload

        assert_equal true, second[:completed]
        assert_equal "completed", coverage.status
        assert_equal 3, coverage.processed_outputs_count
        assert_equal 2, coverage.pages_processed
        assert_equal 3, Address.where.not(cluster_id: nil).count
      end

      test "marks failed when projection changes before processing" do
        prepare_projected_block(
          [VALID_ADDRESS]
        )

        Layer1TxOutputProjectionBlock
          .find_by!(height: @height)
          .update!(
            status: "pending"
          )

        assert_raises RuntimeError do
          process_without_actor_profile_dirty
        end

        coverage =
          ClusterCoverageBlock.find_by!(height: @height)

        assert_equal "failed", coverage.status
        assert_match "TxOutput projection not ready", coverage.last_error
        assert_nil coverage.after_tx_output_id
      end

      private

      def prepare_projected_block(addresses)
        create_cluster_block

        addresses.each_with_index do |address, index|
          create_tx_output(
            address: address,
            vout: index
          )
        end

        create_projection(
          status: "projected",
          expected_outputs_count: addresses.size,
          projected_outputs_count: addresses.size
        )

        result =
          Clusters::Coverage::PrepareBlock.call(
            height: @height
          )

        assert_equal true, result[:prepared]
        result
      end

      def process_without_actor_profile_dirty(batch_size: 500)
        ActorProfiles::DirtyMarker.stub(:mark, ->(_cluster_id) { raise "dirty marker called" }) do
          Clusters::Coverage::ProcessPage.call(
            height: @height,
            batch_size: batch_size
          )
        end
      end

      def create_cluster_block(
        height: @height,
        block_hash: @block_hash
      )
        ClusterProcessedBlock.create!(
          height: height,
          block_hash: block_hash,
          status: "processed",
          processed_at: Time.current
        )
      end

      def create_projection(
        height: @height,
        block_hash: @block_hash,
        status:,
        expected_outputs_count:,
        projected_outputs_count:
      )
        Layer1TxOutputProjectionBlock.create!(
          height: height,
          block_hash: block_hash,
          status: status,
          expected_outputs_count: expected_outputs_count,
          expected_outputs_value_btc: BigDecimal("0"),
          projected_outputs_count: projected_outputs_count,
          projected_outputs_value_btc: BigDecimal("0"),
          completed_at: status == "projected" ? Time.current : nil
        )
      end

      def create_tx_output(
        address:,
        vout:
      )
        TxOutput.create!(
          txid: unique_hash("tx"),
          vout: vout,
          address: address,
          amount_btc: "0.1",
          block_height: @height,
          block_hash: @block_hash,
          block_time: Time.current
        )
      end

      def create_bootstrap_baseline(
        incremental_start_height:
      )
        ClusterCoverageBlock.create!(
          height: incremental_start_height,
          block_hash: @block_hash,
          status: "completed",
          expected_outputs_count: 0,
          processed_outputs_count: 0,
          expected_address_outputs_count: 0,
          processed_address_outputs_count: 0,
          metadata: {
            "mode" => "bootstrap",
            "source" => "coverage_v1",
            "incremental_start_height" =>
              incremental_start_height.to_s,
            "snapshot_max_address_id" =>
              "0",
            "historical_null_addresses_processed" =>
              "0"
          }
        )
      end

      def valid_bech32_address
        program =
          Array.new(20, 42)

        data =
          [0] +
          Bech32.convert_bits(
            program,
            8,
            5,
            true
          )

        Bech32.encode(
          "bc",
          data,
          Bech32::Encoding::BECH32
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
        AddressLink.delete_all
        ClusterCoverageBlock.delete_all
        Layer1TxOutputProjectionBlock.delete_all
        TxOutput.delete_all
        Address.delete_all
        ClusterProcessedBlock.delete_all
        Cluster.delete_all
      end
    end
  end
end
