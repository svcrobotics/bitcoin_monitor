# frozen_string_literal: true

require "test_helper"

module System
  module Anomalies
    class Layer1RulesTest < ActiveSupport::TestCase
      self.use_transactional_tests = false

      test "returns no anomaly for nominal observable facts" do
        assert_empty Layer1Rules.call(
          context: {
            pipeline: { layer1: { lag: 0 } },
            layer1_health: { status: "healthy", strict: {} }
          }
        )
      end

      test "emits a warning that requires confirmation" do
        anomaly = Layer1Rules.call(
          context: {
            pipeline: { layer1: { lag: 2 } },
            layer1_health: { status: "warning", strict: {} }
          }
        ).sole

        assert_equal "layer1_health_warning", anomaly[:code]
        assert_equal "warning", anomaly[:severity]
        assert_equal 2, anomaly[:confirmation_observations]
      end

      test "emits critical lag from pipeline facts" do
        anomaly = Layer1Rules.call(
          context: {
            pipeline: {
              bitcoin_core: { best_height: 957_876 },
              layer1: { lag: 30, processed_height: 957_846 }
            },
            layer1_health: { status: "healthy", strict: {} }
          }
        ).sole

        assert_equal "layer1_lag_critical", anomaly[:code]
        assert_equal 30, anomaly.dig(:facts, :lag_blocks)
        assert_equal 957_876, anomaly.dig(:facts, :bitcoin_core_height)
      end

      test "emits layer1 stalled anomaly from health snapshot facts" do
        anomalies =
          Layer1Rules.call(
            context: {
              pipeline: {
                bitcoin_core: {
                  best_height: 957_876
                },
                layer1: {
                  lag: 25,
                  processed_height: 957_851
                }
              },
              layer1_health: {
                status: "warning",
                strict: {
                  stalled: true,
                  stalled_seconds: 61,
                  catch_up_active: true,
                  layer1_work_active: false,
                  layer1_work_queued: false,
                  last_scheduler_tick_at: nil,
                  last_enqueue_at: nil,
                  stalled_reason: "lag_without_strict_work"
                }
              }
            }
          )

        stalled =
          anomalies.find do |anomaly|
            anomaly[:code] == "layer1_stalled"
          end

        assert stalled
        assert_equal "critical", stalled[:severity]
        assert_equal "layer1:stalled", stalled[:fingerprint]
        assert_equal 25, stalled.dig(:facts, :lag_blocks)
        assert_equal 61, stalled.dig(:facts, :stalled_seconds)
      end

      test "emits processing stale only above the certified threshold" do
        threshold = Layer1::Realtime::HealthSnapshot::PROCESSING_STALE_SECONDS
        anomalies = Layer1Rules.call(
          context: {
            pipeline: { layer1: { lag: 0, processing_height: 42 } },
            layer1_health: {
              status: "healthy",
              strict: { processing_stale_seconds: threshold + 1 }
            }
          }
        )

        stale = anomalies.sole
        assert_equal "layer1_processing_stale", stale[:code]
        assert_equal threshold + 1, stale.dig(:facts, :stale_for_seconds)
        assert_equal 42, stale.dig(:facts, :processing_height)
      end
    end
  end
end
