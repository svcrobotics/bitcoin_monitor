# frozen_string_literal: true

require "test_helper"

module System
  module Anomalies
    class Layer1RulesTest < ActiveSupport::TestCase
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
    end
  end
end
