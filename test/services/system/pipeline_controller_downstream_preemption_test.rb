# frozen_string_literal: true

require "test_helper"

module System
  class PipelineControllerDownstreamPreemptionTest <
    ActiveSupport::TestCase

    test "development backfill does not preempt actor behavior within guardrails" do
      with_development_backfill do
        reason =
          PipelineController
            .downstream_preemption_reason(
              :actor_behavior,
              current_snapshot:
                snapshot(
                  layer1_lag: 6,
                  cluster_global_lag: 21
                )
            )

        assert_nil reason
      end
    end

    test "development backfill does not stop an already running actor behavior batch" do
      with_development_backfill do
        current_snapshot =
          snapshot(
            layer1_lag: 5,
            cluster_global_lag: 20
          ).deep_merge(
            actor_behavior: {
              batch_running: true,
              cooldown_active: true,
              work_available: true
            }
          )

        reason =
          PipelineController
            .downstream_preemption_reason(
              :actor_behavior,
              current_snapshot:
                current_snapshot
            )

        assert_nil reason
      end
    end

    test "development backfill preempts when layer1 exceeds its guardrail" do
      with_development_backfill do
        reason =
          PipelineController
            .downstream_preemption_reason(
              :actor_behavior,
              current_snapshot:
                snapshot(
                  layer1_lag: 21,
                  cluster_global_lag: 21
                )
            )

        assert_equal(
          :development_backfill_upstream_guardrail,
          reason
        )
      end
    end

    test "development backfill preempts when cluster exceeds its guardrail" do
      with_development_backfill do
        reason =
          PipelineController
            .downstream_preemption_reason(
              :actor_behavior,
              current_snapshot:
                snapshot(
                  layer1_lag: 6,
                  cluster_global_lag: 31
                )
            )

        assert_equal(
          :development_backfill_upstream_guardrail,
          reason
        )
      end
    end

    private

    def snapshot(
      layer1_lag:,
      cluster_global_lag:
    )
      {
        bitcoin_core: {
          available: true,
          best_height: 956_772
        },

        layer1: {
          checkpoint_available: true,
          lag: layer1_lag,
          processing: false,
          buffers_empty: true,
          strict_queue_size: 0,
          strict_worker_busy: false
        },

        cluster: {
          checkpoint_available: true,
          global_lag: cluster_global_lag,
          processing: false,
          strict_queue_size: 0,
          strict_worker_busy: false
        }
      }
    end

    def with_development_backfill
      previous = {
        "TANSA_PIPELINE_MODE" =>
          ENV["TANSA_PIPELINE_MODE"],

        "TANSA_BACKFILL_MAX_LAYER1_LAG" =>
          ENV["TANSA_BACKFILL_MAX_LAYER1_LAG"],

        "TANSA_BACKFILL_MAX_CLUSTER_GLOBAL_LAG" =>
          ENV["TANSA_BACKFILL_MAX_CLUSTER_GLOBAL_LAG"]
      }

      ENV["TANSA_PIPELINE_MODE"] =
        "development_backfill"

      ENV["TANSA_BACKFILL_MAX_LAYER1_LAG"] =
        "20"

      ENV["TANSA_BACKFILL_MAX_CLUSTER_GLOBAL_LAG"] =
        "30"

      yield
    ensure
      previous.each do |key, value|
        if value.nil?
          ENV.delete(key)
        else
          ENV[key] = value
        end
      end
    end
  end
end
