# frozen_string_literal: true

require "test_helper"

module Blockchain
  module Buffer
    class BlockBufferStrictMetricsTest <
      ActiveSupport::TestCase

      test "persists complete strict metrics on processed block" do
        height = 9_999_991

        block =
          BlockBufferModel.create!(
            height: height,
            block_hash: "a" * 64,
            status: "processing"
          )

        result =
          BlockBuffer.mark_processed(
            height,
            metrics: {
              duration_ms: 1_250,
              strict_outputs: 9_355,
              cluster_inputs: 7_844,
              outputs_audit_ok: true,

              stage_timings: {
                audit_outputs: 956,
                audit_inputs: 616
              }
            }
          )

        assert_equal true, result

        block.reload

        assert_equal 1_250, block.duration_ms

        metrics =
          block
            .strict_metrics
            .with_indifferent_access

        assert_equal(
          9_355,
          metrics[:strict_outputs]
        )

        assert_equal(
          7_844,
          metrics[:cluster_inputs]
        )

        assert_equal(
          true,
          metrics[:outputs_audit_ok]
        )

        assert_equal(
          956,
          metrics.dig(
            :stage_timings,
            :audit_outputs
          )
        )
      end

      test "empty or absent metrics preserve persisted strict metrics" do
        block =
          create_block(
            height: 9_999_992,
            strict_metrics: {
              "strict_outputs" => 9_355,
              "stage_timings" => {
                "audit_outputs" => 956
              }
            }
          )

        expected_metrics =
          block.strict_metrics.deep_dup

        BlockBuffer.mark_processed(
          block.height,
          metrics: nil
        )
        assert_equal expected_metrics, block.reload.strict_metrics

        BlockBuffer.mark_processed(
          block.height,
          metrics: {}
        )
        assert_equal expected_metrics, block.reload.strict_metrics

        BlockBuffer.mark_processed(block.height)
        assert_equal expected_metrics, block.reload.strict_metrics
      end

      test "recursively merges partial metrics with new values winning" do
        block =
          create_block(
            height: 9_999_993,
            strict_metrics: {
              "strict_outputs" => 9_000,
              "cluster_inputs" => 7_844,
              "stage_timings" => {
                "audit_outputs" => 900,
                "audit_inputs" => 616
              }
            }
          )

        BlockBuffer.mark_processed(
          block.height,
          metrics: {
            strict_outputs: 9_355,
            outputs_audit_ok: true,
            stage_timings: {
              audit_outputs: 956
            }
          }
        )

        assert_equal(
          {
            "strict_outputs" => 9_355,
            "cluster_inputs" => 7_844,
            "outputs_audit_ok" => true,
            "stage_timings" => {
              "audit_outputs" => 956,
              "audit_inputs" => 616
            }
          },
          block.reload.strict_metrics
        )
      end

      test "strict metrics update preserves unrelated block attributes" do
        block_time = Time.zone.parse("2026-07-05 17:16:05")
        block =
          create_block(
            height: 9_999_994,
            block_hash: "b" * 64,
            previous_hash: "c" * 64,
            tx_count: 2_345,
            size_bytes: 1_234_567,
            block_time: block_time,
            attempts: 3,
            strict_metrics: {
              "strict_outputs" => 9_000
            }
          )

        preserved_attributes =
          block.attributes.slice(
            "height",
            "block_hash",
            "previous_hash",
            "tx_count",
            "size_bytes",
            "block_time",
            "attempts",
            "created_at"
          )

        BlockBuffer.mark_processed(
          block.height,
          metrics: {
            strict_outputs: 9_355
          }
        )

        assert_equal(
          preserved_attributes,
          block.reload.attributes.slice(
            *preserved_attributes.keys
          )
        )
      end

      private

      def create_block(height:, **attributes)
        BlockBufferModel.create!(
          {
            height: height,
            block_hash: "a" * 64,
            status: "processing"
          }.merge(attributes)
        )
      end
    end
  end
end
