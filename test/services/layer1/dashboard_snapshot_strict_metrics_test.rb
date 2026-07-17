# frozen_string_literal: true

require "test_helper"

module Layer1
  class DashboardSnapshotStrictMetricsTest <
    ActiveSupport::TestCase

    test "exposes latest processed block and its strict metrics through performance" do
      height = 9_999_992

      BlockBufferModel.create!(
        height: height,
        block_hash: "b" * 64,
        previous_hash: "c" * 64,
        status: "processed",
        tx_count: 3_622,
        size_bytes: 1_500_000,
        duration_ms: 100_174,
        processed_at: Time.current,

        strict_metrics: {
          strict_outputs: 9_355,
          cluster_inputs: 7_844,
          outputs_audit_ok: true,
          inputs_audit_ok: true,
          utxo_audit_ok: true,

          stage_timings: {
            block_processor: 2_134,
            flush_buffers_until_empty: 95_196
          },

          flush_metrics: {
            version: 1,
            iterations_count: 1,

            outputs: {
              rows_flushed: 9_355,
              duration_ms: 30_000,
              ms_per_row: 3.207,

              stage_timings: {
                insert_utxo_outputs: 28_000
              }
            },

            spent: {
              rows_flushed: 7_844,
              duration_ms: 65_196,
              ms_per_row: 8.311,

              stage_timings: {
                bulk_upsert_cluster_inputs: 60_000,
                bulk_delete_utxo_outputs: 4_000
              }
            }
          }
        }
      )

      service =
        DashboardSnapshot.new(
          snapshot: {
            status: "healthy",
            bitcoin_core_height: height,
            processed_height: height,
            lag: 0,
            buffers: {
              outputs: 0,
              spent: 0
            },
            activity: {
              pipeline_state: "idle_synced"
            },
            strict: {}
          }
        )

      service.define_singleton_method(
        :proof_snapshot
      ) do
        {
          total_checks: 0,
          passed_checks: 0,
          compliance: nil,
          conformant: false
        }
      end

      dashboard =
        service.call

      details =
        dashboard.dig(
          :performance,
          :last_block
        )

      assert_not_nil details
      assert_equal height, details[:height]
      assert_equal 3_622, details[:tx_count]
      assert_equal 9_355, details[:strict_outputs_count]
      assert_equal 7_844, details[:cluster_inputs_count]
      assert_equal true, details[:outputs_audit_ok]
      assert_equal true, details[:inputs_audit_ok]
      assert_equal true, details[:utxo_audit_ok]

      assert_equal(
        7_844,
        details.dig(
          :flush_metrics,
          :spent,
          :rows_flushed
        )
      )

      assert_equal(
        60_000,
        details.dig(
          :flush_metrics,
          :spent,
          :stage_timings,
          :bulk_upsert_cluster_inputs
        )
      )

      assert_equal(
        95_196,
        details.dig(
          :stage_timings,
          :flush_buffers_until_empty
        )
      )
    end
  end
end
