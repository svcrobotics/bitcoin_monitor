# frozen_string_literal: true

require "bech32"
require "minitest/mock"
require "test_helper"

module Clusters
  module Coverage
    class AddressRunnerTest < ActiveSupport::TestCase
      SeparateConnectionBase =
        Class.new(ActiveRecord::Base) do
          self.abstract_class = true
        end

      test "clusters addresses created from outputs without tx output projection dependency" do
        address =
          Address.create!(
            address: segwit_address(1),
            first_seen_height: 955_200
          )

        assert_difference -> { Cluster.count }, 1 do
          result =
            Clusters::Coverage::AddressRunner.call(
              batch_size: 10,
              max_batches: 1,
              lock: false
            )

          assert_equal true, result[:ok]
          assert_equal 1, result[:updated]
          assert_equal 1, result[:singleton_clusters_created]
        end

        assert address.reload.cluster_id.present?
      end

      test "clusters addresses created only from input facts" do
        address =
          Address.create!(
            address: segwit_address(2),
            first_seen_height: 955_369,
            last_seen_height: 955_369
          )

        ClusterInput.create!(
          block_height: 955_000,
          txid: unique_hash("input-only"),
          vout: 0,
          address: address.address,
          amount_btc: BigDecimal("0.1"),
          spent: true,
          spent_txid: unique_hash("spent"),
          spent_block_height: 955_369,
          cluster_processed_at: Time.current
        )

        result =
          Clusters::Coverage::AddressRunner.call(
            batch_size: 10,
            max_batches: 1,
            lock: false
          )

        assert_equal true, result[:ok]
        assert_equal 1, result[:updated]
        assert address.reload.cluster_id.present?
      end

      test "freezes high watermark and ignores addresses created during the page" do
        first =
          Address.create!(
            address: segwit_address(3)
          )

        created_during_page = nil

        maximum =
          lambda do |_column|
            created_during_page =
              Address.create!(
                address: segwit_address(4)
              )

            first.id
          end

        Address.stub(:maximum, maximum) do
          result =
            Clusters::Coverage::AddressRunner.call(
              batch_size: 10,
              max_batches: 1,
              lock: false
            )

          assert_equal true, result[:ok]
          assert_equal first.id, result[:high_watermark]
        end

        assert first.reload.cluster_id.present?
        assert_nil created_during_page.reload.cluster_id
      end

      test "resumes after a partial cursor run" do
        first =
          Address.create!(
            address: segwit_address(5)
          )

        second =
          Address.create!(
            address: segwit_address(6)
          )

        first_result =
          Clusters::Coverage::AddressRunner.call(
            batch_size: 1,
            max_batches: 1,
            lock: false
          )

        assert_equal "max_batches", first_result[:stopped_reason]
        assert_equal first.id, cursor_record.reload.after_tx_output_id
        assert first.reload.cluster_id.present?
        assert_nil second.reload.cluster_id

        second_result =
          Clusters::Coverage::AddressRunner.call(
            batch_size: 1,
            max_batches: 5,
            lock: false
          )

        assert_equal true, second_result[:ok]
        assert second.reload.cluster_id.present?
      end

      test "advances cursor over already clustered addresses" do
        cluster =
          Cluster.create!(
            composition_version: 9
          )

        already =
          Address.create!(
            address: segwit_address(7),
            cluster: cluster
          )

        pending =
          Address.create!(
            address: segwit_address(8)
          )

        result =
          Clusters::Coverage::AddressRunner.call(
            batch_size: 2,
            max_batches: 1,
            lock: false
          )

        assert_equal true, result[:ok]
        assert_equal 2, result[:scanned]
        assert_equal 1, result[:already_clustered]
        assert_equal 1, result[:updated]
        assert_equal pending.id, cursor_record.reload.after_tx_output_id
        assert_equal cluster.id, already.reload.cluster_id
        assert pending.reload.cluster_id.present?
      end

      test "reconciliation fixes an old hole below the cursor" do
        old_hole =
          Address.create!(
            address: segwit_address(9)
          )

        cursor =
          cursor_record

        cursor.update!(
          status: "completed",
          block_hash: Clusters::Coverage::AddressCursor::BLOCK_HASH,
          after_tx_output_id: old_hole.id + 100,
          max_tx_output_id: old_hole.id + 100,
          metadata:
            cursor.metadata.merge(
              "source" => "addresses",
              "profile_version" => "address_coverage_v1",
              "last_processed_address_id" =>
                (old_hole.id + 100).to_s,
              "high_watermark_address_id" =>
                (old_hole.id + 100).to_s
            )
        )

        result =
          Clusters::Coverage::AddressRunner.call(
            batch_size: 10,
            max_batches: 1,
            reconcile: true,
            lock: false
          )

        assert_equal true, result[:ok]
        assert_equal 1, result[:updated]
        assert old_hole.reload.cluster_id.present?
      end

      test "reconciliation is paginated and resumes secondary cursor" do
        first =
          Address.create!(
            address: segwit_address(90)
          )

        second =
          Address.create!(
            address: segwit_address(91)
          )

        third =
          Address.create!(
            address: segwit_address(92)
          )

        cursor =
          cursor_record

        cursor.update!(
          status: "completed",
          after_tx_output_id: third.id,
          max_tx_output_id: third.id,
          metadata:
            cursor.metadata.merge(
              "source" => "addresses",
              "profile_version" => "address_coverage_v1",
              "reconciliation_after_address_id" => "0"
            )
        )

        first_result =
          Clusters::Coverage::AddressRunner.call(
            batch_size: 1,
            max_batches: 1,
            reconcile: true,
            lock: false
          )

        assert_equal first.id, first_result[:last_address_id]
        assert first.reload.cluster_id.present?
        assert_nil second.reload.cluster_id
        assert_equal(
          first.id.to_s,
          cursor_record
            .reload
            .metadata
            .fetch("reconciliation_after_address_id")
        )

        second_result =
          Clusters::Coverage::AddressRunner.call(
            batch_size: 1,
            max_batches: 1,
            reconcile: true,
            lock: false
          )

        assert_equal second.id, second_result[:last_address_id]
        assert second.reload.cluster_id.present?
        assert_nil third.reload.cluster_id
      end

      test "reconciliation empty batch keeps secondary cursor at high watermark" do
        address =
          Address.create!(
            address: segwit_address(93)
          )

        cluster =
          Cluster.create!(
            composition_version: 1
          )

        address.update!(
          cluster: cluster
        )

        cursor =
          cursor_record

        cursor.update!(
          status: "completed",
          after_tx_output_id: address.id,
          max_tx_output_id: address.id,
          metadata:
            cursor.metadata.merge(
              "source" => "addresses",
              "profile_version" => "address_coverage_v1",
              "reconciliation_after_address_id" => "0"
            )
        )

        result =
          Clusters::Coverage::AddressRunner.call(
            batch_size: 1,
            max_batches: 1,
            reconcile: true,
            lock: false
          )

        assert_equal "empty_batch", result[:stopped_reason]
        assert_equal(
          address.id.to_s,
          cursor_record
            .reload
            .metadata
            .fetch("reconciliation_after_address_id")
        )
      end

      test "coverage defers addresses still owned by pending strict cluster input" do
        address =
          Address.create!(
            address: segwit_address(94)
          )

        ClusterInput.create!(
          block_height: 955_100,
          txid: unique_hash("pending-input"),
          vout: 0,
          address: address.address,
          amount_btc: BigDecimal("0.2"),
          spent: true,
          spent_txid: unique_hash("pending-spent"),
          spent_block_height: 955_369,
          cluster_processed_at: nil
        )

        assert_no_difference -> { Cluster.count } do
          result =
            Clusters::Coverage::AddressRunner.call(
              batch_size: 10,
              max_batches: 1,
              lock: false
            )

          assert_equal true, result[:ok]
          assert_equal 1, result[:skipped_pending_cluster_inputs]
          assert_equal 0, result[:updated]
        end

        assert_nil address.reload.cluster_id
      end

      test "coverage does not leave an empty singleton during strict merge race" do
        address =
          Address.create!(
            address: segwit_address(95)
          )

        ClusterInput.create!(
          block_height: 955_101,
          txid: unique_hash("race-input"),
          vout: 0,
          address: address.address,
          amount_btc: BigDecimal("0.3"),
          spent: true,
          spent_txid: unique_hash("race-spent"),
          spent_block_height: 955_370,
          cluster_processed_at: nil
        )

        empty_clusters_before =
          empty_clusters_count

        coverage_result =
          Clusters::Coverage::AddressRunner.call(
            batch_size: 10,
            max_batches: 1,
            lock: false
          )

        assert_equal 0, coverage_result[:updated]
        assert_nil address.reload.cluster_id

        assert_no_difference -> { AddressLink.count } do
          strict_result =
            Clusters::ClusterMerger.call(
              address_records: [address.reload]
            )

          assert_equal 1, strict_result.created
          assert_equal 0, strict_result.merged
        end

        address.reload
        final_cluster =
          Cluster.find(address.cluster_id)

        assert_equal 1, final_cluster.composition_version
        assert_equal 1, final_cluster.address_count
        assert_equal(
          empty_clusters_before,
          empty_clusters_count
        )
      end

      test "concurrent workers use a separate advisory lock" do
        with_separate_connection do |connection|
          assert_equal(
            true,
            advisory_lock(connection)
          )

          result =
            Clusters::Coverage::AddressRunner.call(
              batch_size: 1,
              max_batches: 1,
              lock: true
            )

          assert_equal false, result[:ok]
          assert_equal false, result[:locked]
          assert_equal "already_running", result[:stopped_reason]
        ensure
          advisory_unlock(connection)
        end
      end

      test "does not create address links or merge addresses" do
        first =
          Address.create!(
            address: segwit_address(10)
          )

        second =
          Address.create!(
            address: segwit_address(11)
          )

        assert_difference -> { Cluster.count }, 2 do
          assert_no_difference -> { AddressLink.count } do
            result =
              Clusters::Coverage::AddressRunner.call(
                batch_size: 10,
                max_batches: 1,
                lock: false
              )

            assert_equal 2, result[:updated]
            assert_equal 2, result[:singleton_clusters_created]
          end
        end

        assert_equal(
          2,
          [
            first.reload.cluster_id,
            second.reload.cluster_id
          ].uniq.size
        )
      end

      test "coexists with bootstrap baseline and block coverage records" do
        ClusterCoverageBlock.create!(
          height: 955_136,
          block_hash: unique_hash("baseline"),
          status: "completed",
          metadata: {
            "mode" => "bootstrap",
            "source" => "coverage_v1",
            "incremental_start_height" => "955136"
          }
        )

        ClusterCoverageBlock.create!(
          height: 955_137,
          block_hash: unique_hash("block"),
          status: "pending",
          metadata: {
            "source" => "cluster_coverage_incremental_v1"
          }
        )

        Address.create!(
          address: segwit_address(12)
        )

        assert_difference -> { ClusterCoverageBlock.count }, 1 do
          Clusters::Coverage::AddressRunner.call(
            batch_size: 10,
            max_batches: 1,
            lock: false
          )
        end

        assert ClusterCoverageBlock.find_by!(
          height: 955_136
        ).completed?
        assert ClusterCoverageBlock.find_by!(
          height: 955_137
        ).present?
        assert_equal(
          0,
          ClusterCoverageBlock.find_by!(
            height: Clusters::Coverage::AddressCursor::HEIGHT
          ).height
        )
      end

      test "address cursor is isolated from block coverage scopes" do
        address_cursor =
          cursor_record

        block_record =
          ClusterCoverageBlock.create!(
            height: 955_138,
            block_hash: unique_hash("block-scope"),
            status: "pending",
            metadata: {
              "source" => "cluster_coverage_incremental_v1"
            }
          )

        assert_includes ClusterCoverageBlock.address_coverage, address_cursor
        assert_not_includes ClusterCoverageBlock.block_coverage, address_cursor
        assert_includes ClusterCoverageBlock.block_coverage, block_record
        assert_not_includes ClusterCoverageBlock.pending_or_failed, address_cursor
        assert_includes ClusterCoverageBlock.pending_or_failed, block_record
      end

      test "address cursor does not affect bootstrap baseline or next block selection" do
        cursor_record

        baseline_hash =
          unique_hash("baseline")

        ClusterCoverageBlock.create!(
          height: 955_136,
          block_hash: baseline_hash,
          status: "completed",
          metadata: {
            "mode" => "bootstrap",
            "source" => "coverage_v1",
            "incremental_start_height" => "955136"
          }
        )

        block_hash =
          unique_hash("projected")

        ClusterProcessedBlock.create!(
          height: 955_137,
          block_hash: block_hash,
          status: "processed",
          processed_at: Time.current
        )

        Layer1TxOutputProjectionBlock.create!(
          height: 955_137,
          block_hash: block_hash,
          status: "projected",
          expected_outputs_count: 0,
          projected_outputs_count: 0
        )

        result =
          Clusters::Coverage::PrepareBlock.call

        assert_equal true, result[:prepared]
        assert_equal 955_137, result[:height]
      end

      test "address cursor has a single durable row" do
        first =
          cursor_record

        second =
          cursor_record

        assert_equal first.id, second.id
        assert_equal 1, ClusterCoverageBlock.address_coverage.count
      end

      test "block coverage processor rejects address cursor height" do
        cursor_record

        assert_raises(ArgumentError) do
          Clusters::Coverage::ProcessPage.call(
            height: Clusters::Coverage::AddressCursor::HEIGHT
          )
        end
      end

      test "address health snapshot reports completion by nulls up to cursor" do
        covered =
          Address.create!(
            address: segwit_address(96)
          )

        later =
          Address.create!(
            address: segwit_address(97)
          )

        cluster =
          Cluster.create!(
            composition_version: 1
          )

        covered.update!(
          cluster: cluster
        )

        cursor =
          cursor_record

        cursor.update!(
          status: "completed",
          after_tx_output_id: covered.id,
          max_tx_output_id: covered.id,
          completed_at: Time.current,
          metadata:
            cursor.metadata.merge(
              "source" => "addresses",
              "profile_version" => "address_coverage_v1"
            )
        )

        snapshot =
          Clusters::Coverage::AddressHealthSnapshot.call

        assert_equal covered.id, snapshot[:last_processed_address_id]
        assert_operator snapshot[:current_max_address_id], :>=, later.id
        assert_equal 0, snapshot[:null_addresses_up_to_cursor]
        assert_equal 1, snapshot[:null_addresses_after_cursor]
        assert_equal later.id, snapshot[:oldest_null_address_id]
        assert_equal "completed", snapshot[:status]
      end

      test "does not reference actor profile actor labels or tx output projection" do
        source =
          [
            "app/services/clusters/coverage/address_cursor.rb",
            "app/services/clusters/coverage/address_page.rb",
            "app/services/clusters/coverage/address_runner.rb"
          ].map do |path|
            Rails.root.join(path).read
          end.join("\n")

        refute_match(/ActorProfile|ActorProfiles|ActorLabel|ActorLabels/, source)
        refute_match(/Layer1TxOutputProjectionBlock|TxOutputProjection/, source)
      end

      private

      def cursor_record
        ClusterCoverageBlock.transaction do
          record =
            Clusters::Coverage::AddressCursor.record

          record.save! if record.new_record?
          record
        end
      end

      def segwit_address(seed)
        program =
          Array.new(20, seed)

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
          "#{prefix}-#{SecureRandom.hex(8)}"
        )
      end

      def empty_clusters_count
        Cluster
          .where
          .not(
            id:
              Address
                .where
                .not(cluster_id: nil)
                .select(:cluster_id)
          )
          .count
      end

      def with_separate_connection
        SeparateConnectionBase.establish_connection(
          ActiveRecord::Base
            .connection_db_config
            .configuration_hash
        )

        yield SeparateConnectionBase.connection
      ensure
        SeparateConnectionBase.connection_pool.disconnect!
      end

      def advisory_lock(connection)
        value =
          connection.select_value(
            "SELECT pg_try_advisory_lock(" \
            "#{Clusters::Coverage::AddressRunner::ADVISORY_LOCK_KEY})"
          )

        value == true || value == "t"
      end

      def advisory_unlock(connection)
        connection.select_value(
          "SELECT pg_advisory_unlock(" \
          "#{Clusters::Coverage::AddressRunner::ADVISORY_LOCK_KEY})"
        )
      end
    end
  end
end
