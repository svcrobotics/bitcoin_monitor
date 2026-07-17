# frozen_string_literal: true

require "test_helper"

module Layer1
  class StrictWindowRebuilderFlushMetricsTest <
    ActiveSupport::TestCase

    test "normalizes flusher metrics and computes milliseconds per row" do
      service =
        StrictWindowRebuilder.allocate

      result =
        service.send(
          :normalize_flush_result,
          {
            ok: true,
            flushed: 5_000,
            duration_ms: 44_000,
            cluster_inserted: 4_800,
            utxo_deleted: 4_900,
            missing_utxo: 100,

            stage_timings: {
              pop_batch: 25,
              copy_rows: 170,
              bulk_upsert_cluster_inputs:
                35_000,
              bulk_delete_utxo_outputs:
                8_000
            }
          },
          measured_duration_ms:
            44_100
        )

      assert_equal(
        5_000,
        result[:rows_flushed]
      )

      assert_equal(
        44_000,
        result[:duration_ms]
      )

      assert_equal(
        8.8,
        result[:ms_per_row]
      )

      assert_equal(
        35_000,
        result.dig(
          :stage_timings,
          :bulk_upsert_cluster_inputs
        )
      )

      assert_equal(
        805,
        result[
          :unattributed_duration_ms
        ]
      )

      assert_equal 4_800, result[:cluster_inputs_produced]
      assert_equal 4_900, result[:utxos_deleted]
      assert_equal 100, result[:missing_utxos]
      assert_nil result[:slice_timings]
    end

    test "preserves historical slice timings without inventing stage timings" do
      result =
        StrictWindowRebuilder.allocate.send(
          :normalize_flush_result,
          {
            flushed: 1_000,
            duration_ms: 9_000,
            cluster_inserted: 950,
            utxo_deleted: 975,
            slice_timings: [
              {
                slice: 1,
                rows: 1_000,
                duration_ms: 8_700,
                timings: {
                  spent_utxo_consumer: 7_500,
                  delete_utxo_outputs: 1_000
                }
              }
            ]
          },
          measured_duration_ms: 9_100
        )

      assert_equal 9_000, result[:duration_ms]
      assert_equal 1_000, result[:rows_flushed]
      assert_equal 950, result[:cluster_inputs_produced]
      assert_equal 975, result[:utxos_deleted]
      assert_nil result[:stage_timings]
      assert_nil result[:unattributed_duration_ms]
      assert_equal 8_700, result.dig(:slice_timings, 0, :duration_ms)
      assert_equal 7_500, result.dig(:slice_timings, 0, :timings, :spent_utxo_consumer)
    end

    test "omits metrics and detailed timings that were not measured" do
      result =
        StrictWindowRebuilder.allocate.send(
          :normalize_flush_result,
          { ok: true },
          measured_duration_ms: 321
        )

      assert_equal true, result[:ok]
      assert_equal 321, result[:duration_ms]
      assert_equal 321, result[:measured_duration_ms]
      assert_not result.key?(:rows_flushed)
      assert_not result.key?(:cluster_inputs_produced)
      assert_not result.key?(:utxos_deleted)
      assert_not result.key?(:stage_timings)
      assert_not result.key?(:slice_timings)
      assert_not result.key?(:unattributed_duration_ms)
    end

    test "filters non numeric timing and counter values" do
      result =
        StrictWindowRebuilder.allocate.send(
          :normalize_flush_result,
          {
            flushed: "500",
            cluster_inserted: "490",
            stage_timings: {
              measured: 12,
              text: "13",
              missing: nil
            },
            slice_timings: [
              {
                slice: 1,
                rows: "500",
                duration_ms: 20,
                timings: {
                  valid: 18,
                  invalid: "2"
                }
              }
            ]
          },
          measured_duration_ms: 25
        )

      assert_not result.key?(:rows_flushed)
      assert_not result.key?(:cluster_inputs_produced)
      assert_equal({ measured: 12 }, result[:stage_timings])
      assert_equal 1, result.dig(:slice_timings, 0, :slice)
      assert_not result.dig(:slice_timings, 0).key?(:rows)
      assert_equal({ valid: 18 }, result.dig(:slice_timings, 0, :timings))
    end

    test "aggregates multiple flush iterations" do
      service =
        StrictWindowRebuilder.allocate

      iterations = [
        {
          output: {
            rows_flushed: 10_000,
            duration_ms: 20_000,
            unattributed_duration_ms: 100,

            stage_timings: {
              insert_utxo_outputs:
                19_900
            }
          },

          spent: {
            rows_flushed: 5_000,
            duration_ms: 40_000,
            unattributed_duration_ms: 500,
            cluster_inputs_produced: 4_900,
            utxos_deleted: 4_950,

            stage_timings: {
              bulk_upsert_cluster_inputs:
                35_000,

              bulk_delete_utxo_outputs:
                4_500
            }
          }
        },

        {
          output: {
            rows_flushed: 2_000,
            duration_ms: 5_000,
            unattributed_duration_ms: 50,

            stage_timings: {
              insert_utxo_outputs:
                4_950
            }
          },

          spent: {
            rows_flushed: 1_000,
            duration_ms: 8_000,
            unattributed_duration_ms: 200,
            cluster_inputs_produced: 950,
            utxos_deleted: 975,

            stage_timings: {
              bulk_upsert_cluster_inputs:
                7_000,

              bulk_delete_utxo_outputs:
                800
            }
          }
        }
      ]

      output =
        service.send(
          :aggregate_flush_iterations,
          iterations,
          :output
        )

      spent =
        service.send(
          :aggregate_flush_iterations,
          iterations,
          :spent
        )

      assert_equal 2, output[:calls]
      assert_equal 12_000, output[:rows_flushed]
      assert_equal 25_000, output[:duration_ms]

      assert_equal(
        24_850,
        output.dig(
          :stage_timings,
          :insert_utxo_outputs
        )
      )

      assert_equal 6_000, spent[:rows_flushed]
      assert_equal 48_000, spent[:duration_ms]
      assert_equal 8.0, spent[:ms_per_row]
      assert_equal 5_850, spent[:cluster_inputs_produced]
      assert_equal 5_925, spent[:utxos_deleted]

      assert_equal(
        42_000,
        spent.dig(
          :stage_timings,
          :bulk_upsert_cluster_inputs
        )
      )

      assert_equal(
        5_300,
        spent.dig(
          :stage_timings,
          :bulk_delete_utxo_outputs
        )
      )
    end

    test "merges a second persisted flush snapshot without destroying metrics" do
      height = 956_140
      block = BlockBufferModel.create!(
        height: height,
        block_hash: "f" * 64,
        status: "processing",
        strict_metrics: {
          "existing" => {
            "audit" => "healthy"
          }
        }
      )

      Blockchain::Buffer::BlockBuffer.mark_processed(
        height,
        metrics: {
          flush_metrics: {
            outputs: {
              rows_flushed: 10
            },
            spent: {
              rows_flushed: 5
            }
          }
        }
      )

      Blockchain::Buffer::BlockBuffer.mark_processed(
        height,
        metrics: {
          flush_metrics: {
            outputs: {
              duration_ms: 25
            },
            spent: {
              cluster_inputs_produced: 4,
              utxos_deleted: 5
            }
          }
        }
      )

      metrics = block.reload.strict_metrics.deep_symbolize_keys

      assert_equal "healthy", metrics.dig(:existing, :audit)
      assert_equal 10, metrics.dig(:flush_metrics, :outputs, :rows_flushed)
      assert_equal 25, metrics.dig(:flush_metrics, :outputs, :duration_ms)
      assert_equal 5, metrics.dig(:flush_metrics, :spent, :rows_flushed)
      assert_equal 4, metrics.dig(:flush_metrics, :spent, :cluster_inputs_produced)
      assert_equal 5, metrics.dig(:flush_metrics, :spent, :utxos_deleted)
    end

    test "flush metrics helpers have no orchestration or projection dependency" do
      source = File.read(
        Rails.root.join("app/services/layer1/strict_window_rebuilder.rb")
      )
      metrics_source = source[
        /def flush_buffers_until_empty!.*?(?=\n    def metric_value)/m
      ]

      assert_not_nil metrics_source
      refute_match(/tx_outputs|scheduler|StrictIoLease|presenter|Sidekiq/i, metrics_source)
    end
  end
end
