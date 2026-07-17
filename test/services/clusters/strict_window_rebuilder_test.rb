# frozen_string_literal: true

require "test_helper"

module Clusters
  class StrictWindowRebuilderTest < ActiveSupport::TestCase
    setup do
      ClusterProcessedBlock.delete_all
      BlockBufferModel.delete_all
    end

    test "processes one height and persists a certified checkpoint" do
      height = 954_600
      block_hash = "00clusterstrict#{height}"
      create_layer1_block!(height: height, block_hash: block_hash)

      scan_result = { ok: true, scanned_blocks: 1 }
      audit_result = { ok: true, status: "healthy" }

      with_scanner(scan_result) do
        with_audit(audit_result) do
          result = Clusters::StrictWindowRebuilder.call(
            from_height: height,
            to_height: height
          )

          assert result[:ok]
        end
      end

      checkpoint = ClusterProcessedBlock.find_by!(height: height)

      assert_equal "processed", checkpoint.status
      assert checkpoint.processed_at.present?
      assert_equal block_hash, checkpoint.block_hash
      assert_equal true, checkpoint.scan_result.fetch("ok")
      assert_equal true, checkpoint.audit_result.fetch("ok")
      assert_equal true, checkpoint.cleanup_result.fetch("skipped")
      assert_equal "outside_strict_path", checkpoint.cleanup_result.fetch("mode")
      assert_operator checkpoint.duration_ms.to_i, :>=, 0
      assert checkpoint.stage_timings.key?("scan_ms")
      assert checkpoint.stage_timings.key?("audit_ms")
      assert checkpoint.stage_timings.key?("checkpoint_ms")
    end

    test "persists warning audits as processed checkpoints" do
      height = 954_601
      create_layer1_block!(height: height)

      audit_result = {
        ok: true,
        maintenance_warning: true,
        warnings: [
          {
            check: "empty_clusters",
            count: 2,
            blocking: false
          }
        ]
      }

      with_scanner({ ok: true, scanned_blocks: 1 }) do
        with_audit(audit_result) do
          result = Clusters::StrictWindowRebuilder.call(
            from_height: height,
            to_height: height
          )

          assert result[:ok]
        end
      end

      checkpoint = ClusterProcessedBlock.find_by!(height: height)

      assert_equal "processed", checkpoint.status
      assert_equal true, checkpoint.audit_result.fetch("maintenance_warning")
      assert_equal "empty_clusters", checkpoint.audit_result.fetch("warnings").first.fetch("check")
    end

    test "persists failed checkpoint when audit blocks certification" do
      height = 954_602
      create_layer1_block!(height: height)

      audit_result = {
        ok: false,
        issues: [
          {
            check: "addresses_missing",
            count: 1
          }
        ]
      }

      with_scanner({ ok: true, scanned_blocks: 1 }) do
        with_audit(audit_result) do
          result = Clusters::StrictWindowRebuilder.call(
            from_height: height,
            to_height: height
          )

          refute result[:ok]
        end
      end

      checkpoint = ClusterProcessedBlock.find_by!(height: height)

      assert_equal "failed", checkpoint.status
      assert_nil checkpoint.processed_at
      assert_equal false, checkpoint.audit_result.fetch("ok")
      assert_match(/Cluster audit failed/, checkpoint.error_message)
    end

    test "does not rerun scanner or audit for already certified height with same hash" do
      height = 954_603
      block_hash = "00clusterstrict#{height}"
      create_layer1_block!(height: height, block_hash: block_hash)

      checkpoint =
        create_cluster_checkpoint!(
          height: height,
          block_hash: block_hash,
          status: "processed"
        )

      scanner_calls = 0
      audit_calls = 0

      with_scanner(proc { scanner_calls += 1 }) do
        with_audit(proc { audit_calls += 1 }) do
          result = Clusters::StrictWindowRebuilder.call(
            from_height: height,
            to_height: height
          )

          assert result[:ok]
          assert result[:skipped]
          assert_equal "already_processed", result[:reason]
        end
      end

      assert_equal 0, scanner_calls
      assert_equal 0, audit_calls
      checkpoint.reload
      assert_equal "processed", checkpoint.status
      assert_equal block_hash, checkpoint.block_hash
    end

    test "fails explicitly when certified checkpoint hash differs from Layer1" do
      height = 954_604
      create_layer1_block!(height: height, block_hash: "00new#{height}")
      create_cluster_checkpoint!(
        height: height,
        block_hash: "00old#{height}",
        status: "processed"
      )

      result = Clusters::StrictWindowRebuilder.call(
        from_height: height,
        to_height: height
      )

      refute result[:ok]
      assert_equal "block_hash_mismatch", result[:failed][:message]

      checkpoint = ClusterProcessedBlock.find_by!(height: height)

      assert_equal "failed", checkpoint.status
      assert_equal "00old#{height}", checkpoint.block_hash
    end

    test "persists failed checkpoint and reraises scanner exceptions" do
      height = 954_605
      create_layer1_block!(height: height)

      with_scanner(proc { raise RuntimeError, "scanner boom" }) do
        with_audit({ ok: true }) do
          assert_raises(RuntimeError) do
            Clusters::StrictWindowRebuilder.call(
              from_height: height,
              to_height: height
            )
          end
        end
      end

      checkpoint = ClusterProcessedBlock.find_by!(height: height)

      assert_equal "failed", checkpoint.status
      assert_nil checkpoint.processed_at
      assert_match(/RuntimeError: scanner boom/, checkpoint.error_message)
    end

    test "does not reference global cleanup in the strict execution path" do
      source =
        File.read(
          Rails.root.join(
            "app/services/clusters/strict_window_rebuilder.rb"
          )
        )

      refute_match(/CleanupEmptyClusters/, source)
      refute_match(/left_joins.*addresses/, source)
      refute_match(/Cluster\.count/, source)
      refute_match(/Address\.count/, source)
    end

    test "retries a failed checkpoint and marks it processed after success" do
      height = 954_606
      block_hash = "00clusterstrict#{height}"
      create_layer1_block!(height: height, block_hash: block_hash)
      create_cluster_checkpoint!(
        height: height,
        block_hash: block_hash,
        status: "failed",
        error_message: "previous failure"
      )

      with_scanner({ ok: true, scanned_blocks: 1 }) do
        with_audit({ ok: true }) do
          result = Clusters::StrictWindowRebuilder.call(
            from_height: height,
            to_height: height
          )

          assert result[:ok]
        end
      end

      checkpoint = ClusterProcessedBlock.find_by!(height: height)

      assert_equal "processed", checkpoint.status
      assert checkpoint.processed_at.present?
      assert_nil checkpoint.error_message
    end

    private

    def create_layer1_block!(height:, block_hash: "00clusterstrict#{height}")
      BlockBufferModel.create!(
        height: height,
        block_hash: block_hash,
        status: "processed"
      )
    end

    def create_cluster_checkpoint!(
      height:,
      block_hash:,
      status:,
      error_message: nil
    )
      ClusterProcessedBlock.create!(
        height: height,
        block_hash: block_hash,
        status: status,
        scan_result: {},
        cleanup_result: {},
        audit_result: {},
        processing_started_at: Time.current,
        processed_at: status == "processed" ? Time.current : nil,
        duration_ms: 1,
        stage_timings: {},
        error_message: error_message
      )
    end

    def with_scanner(result_or_callable)
      callable =
        result_or_callable.respond_to?(:call) ?
          result_or_callable :
          proc { result_or_callable }

      with_stubbed_singleton_method(ClusterScanner, :call, callable) do
        yield
      end
    end

    def with_audit(result_or_callable)
      callable =
        result_or_callable.respond_to?(:call) ?
          result_or_callable :
          proc { result_or_callable }

      with_stubbed_singleton_method(Clusters::AuditBlock, :call, callable) do
        yield
      end
    end

    def with_stubbed_singleton_method(target, method_name, replacement)
      original = target.method(method_name)

      target.define_singleton_method(method_name) do |*args, **kwargs, &block|
        replacement.call(*args, **kwargs, &block)
      end

      yield
    ensure
      target.define_singleton_method(method_name) do |*args, **kwargs, &block|
        original.call(*args, **kwargs, &block)
      end
    end
  end
end
