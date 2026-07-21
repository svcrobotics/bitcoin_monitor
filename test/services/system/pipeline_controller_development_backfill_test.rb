# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

module System
  class PipelineControllerDevelopmentBackfillTest <
    ActiveSupport::TestCase

    test "realtime mode keeps the strict Layer1 lag budget" do
      with_pipeline_mode("realtime") do
        snapshot =
          base_snapshot.deep_merge(
            layer1: {
              lag: 4
            },

            cluster: {
              global_lag: 4,
              lag: 4
            }
          )

        decision =
          PipelineController.decision(
            :actor_profile,
            current_snapshot: snapshot
          )

        refute decision[:allowed]

        assert_includes(
          decision[:failed_constraints],
          :actor_profile_layer1_lag_within_budget
        )
      end
    end

    test "development backfill allows actor profile from aligned certified checkpoint" do
      with_pipeline_mode do
        snapshot =
          base_snapshot.deep_merge(
            layer1: {
              lag: 5,
              checkpoint_available: true
            },

            cluster: {
              lag: 0,
              global_lag: 5,
              checkpoint_available: true,
              caught_up_to_layer1: true
            },

            actor_profile: {
              pending_work: 406_000,
              processing: false
            }
          )

        decision =
          PipelineController.decision(
            :actor_profile,
            current_snapshot: snapshot
          )

        assert decision[:allowed]
        assert_empty decision[:failed_constraints]
      end
    end

    test "development backfill pauses actor profile beyond emergency guardrails" do
      with_pipeline_mode do
        snapshot =
          base_snapshot.deep_merge(
            cluster: {
              global_lag: 31
            }
          )

        decision =
          PipelineController.decision(
            :actor_profile,
            current_snapshot: snapshot
          )

        refute decision[:allowed]

        assert_includes(
          decision[:failed_constraints],
          :development_backfill_upstream_within_guardrails
        )
      end
    end

    test "development backfill keeps layer1 thresholded but wakes cluster when behind layer1" do
      with_pipeline_mode do
        snapshot =
          base_snapshot.deep_merge(
            layer1: {
              lag: 3,
              processing: false,
              buffers: {
                outputs: 0,
                spent: 0
              },
              buffers_empty: true,
              strict_queue_size: 0,
              strict_worker_busy: false,
              checkpoint_available: true
            },

            cluster: {
              lag: 2,
              global_lag: 5,
              processing: false,
              strict_queue_size: 0,
              strict_worker_busy: false,
              checkpoint_available: true,
              caught_up_to_layer1: false
            },

            strict_io: {
              owner: nil
            }
          )

        layer1_decision =
          PipelineController.decision(
            :layer1_realtime,
            current_snapshot: snapshot
          )

        cluster_decision =
          PipelineController.decision(
            :cluster,
            current_snapshot: snapshot
          )

        refute(
          PipelineController.work_available?(
            layer1_decision
          )
        )

        assert cluster_decision[:allowed]
        assert_empty cluster_decision[:failed_constraints]

        assert(
          PipelineController.work_available?(
            cluster_decision
          )
        )
      end
    end

    test "development backfill lets downstream consume incrementally" do
      with_pipeline_mode do
        actor_behavior =
          PipelineController.send(
            :development_backfill_downstream_decision,
            {
              module: :actor_behavior,
              allowed: false,
              state: :blocked,
              reason: :actor_profile_priority,
              failed_constraints: [
                :actor_profile_no_pending_work
              ],
              actor_behavior: {
                auto_enabled: true,
                work_available: true,
                cooldown_active: false,
                batch_running: false,
                stale_running_run: false
              }
            },
            current_snapshot: base_snapshot
          )

        actor_labels =
          PipelineController.send(
            :development_backfill_downstream_decision,
            {
              module: :actor_labels,
              allowed: false,
              state: :blocked,
              reason: :actor_profile_priority,
              failed_constraints: [
                :actor_profile_no_pending_work
              ],
              actor_labels: {
                work_available: true,
                cooldown_active: false,
                lock_present: false,
                worker_write_enabled: true
              }
            },
            current_snapshot: base_snapshot
          )

        assert actor_behavior[:allowed]
        assert_equal :run, actor_behavior[:state]

        assert actor_labels[:allowed]
        assert_equal :run, actor_labels[:state]
      end
    end

    test "development backfill permits actor profile while layer1 processes beyond an aligned checkpoint" do
      with_pipeline_mode do
        snapshot =
          base_snapshot.deep_merge(
            layer1: {
              lag: 3,
              processing: true,
              checkpoint_available: true
            },

            cluster: {
              lag: 0,
              global_lag: 3,
              checkpoint_available: true,
              caught_up_to_layer1: true
            },

            actor_profile: {
              pending_work: 406_000,
              processing: false
            }
          )

        decision =
          PipelineController.decision(
            :actor_profile,
            current_snapshot: snapshot
          )

        assert decision[:allowed]
        assert_empty decision[:failed_constraints]
      end
    end

    test "development backfill permits downstream during layer1 priority" do
      with_pipeline_mode do
        decision =
          PipelineController.send(
            :development_backfill_downstream_decision,
            {
              module: :actor_behavior,
              allowed: false,
              state: :blocked,
              reason: :layer1_realtime_priority,
              failed_constraints: [
                :layer1_not_processing,
                :layer1_buffers_empty
              ],
              actor_behavior: {
                auto_enabled: true,
                work_available: true,
                cooldown_active: false,
                batch_running: false,
                stale_running_run: false
              }
            },
            current_snapshot: base_snapshot.deep_merge(
              layer1: {
                lag: 3,
                processing: true,
                buffers_empty: false
              }
            )
          )

        assert decision[:allowed]
        assert_equal :run, decision[:state]
        assert_nil decision[:reason]
      end
    end

    test "development backfill permits labels during cluster priority" do
      with_pipeline_mode do
        decision =
          PipelineController.send(
            :development_backfill_downstream_decision,
            {
              module: :actor_labels,
              allowed: false,
              state: :blocked,
              reason: :cluster_strict_priority,
              failed_constraints: [
                :cluster_caught_up_to_layer1
              ],
              actor_labels: {
                work_available: true,
                cooldown_active: false,
                lock_present: false,
                worker_write_enabled: true
              }
            },
            current_snapshot: base_snapshot
          )

        assert decision[:allowed]
        assert_equal :run, decision[:state]
        assert_nil decision[:reason]
      end
    end

    test "development backfill still blocks beyond layer1 emergency lag" do
      with_pipeline_mode do
        snapshot =
          base_snapshot.deep_merge(
            layer1: {
              lag: 21
            }
          )

        decision =
          PipelineController.decision(
            :actor_profile,
            current_snapshot: snapshot
          )

        refute decision[:allowed]

        assert_includes(
          decision[:failed_constraints],
          :development_backfill_upstream_within_guardrails
        )
      end
    end


    test "development backfill lets cluster catch up to the available layer1 checkpoint" do
      with_pipeline_mode do
        snapshot =
          base_snapshot.deep_merge(
            layer1: {
              lag: 5,
              processing: false,
              buffers: {
                outputs: 0,
                spent: 0
              },
              buffers_empty: true,
              strict_queue_size: 0,
              strict_worker_busy: false,
              checkpoint_available: true
            },

            cluster: {
              lag: 15,
              global_lag: 20,
              processing: false,
              strict_queue_size: 0,
              strict_worker_busy: false,
              checkpoint_available: true,
              caught_up_to_layer1: false
            }
          )

        decision =
          PipelineController.decision(
            :cluster,
            current_snapshot: snapshot
          )

        assert decision[:allowed]
        assert_empty decision[:failed_constraints]
        assert PipelineController.work_available?(decision)
      end
    end

    test "development backfill permits actor profile from certified cluster checkpoint while cluster trails layer1" do
      with_pipeline_mode do
        snapshot =
          base_snapshot.deep_merge(
            layer1: {
              lag: 5,
              checkpoint_available: true
            },

            cluster: {
              lag: 5,
              global_lag: 10,
              checkpoint_available: true,
              caught_up_to_layer1: false
            },

            actor_profile: {
              pending_work: 406_000,
              processing: false
            }
          )

        decision =
          PipelineController.decision(
            :actor_profile,
            current_snapshot: snapshot
          )

        assert decision[:allowed]
        assert_empty decision[:failed_constraints]

        refute_includes(
          decision[:constraints],
          :cluster_caught_up_to_layer1
        )

        refute_includes(
          decision[:constraints],
          :actor_profile_cluster_lag_within_budget
        )
      end
    end

    test "development backfill blocks actor profile beyond emergency guardrails" do
      with_pipeline_mode do
        snapshot =
          base_snapshot.deep_merge(
            layer1: {
              lag: 5,
              checkpoint_available: true
            },

            cluster: {
              lag: 31,
              global_lag: 31,
              checkpoint_available: true,
              caught_up_to_layer1: false
            },

            actor_profile: {
              pending_work: 406_000,
              processing: false
            }
          )

        decision =
          PipelineController.decision(
            :actor_profile,
            current_snapshot: snapshot
          )

        refute decision[:allowed]

        assert_equal(
          :development_backfill_upstream_within_guardrails,
          decision[:reason]
        )

        assert_includes(
          decision[:failed_constraints],
          :development_backfill_upstream_within_guardrails
        )
      end
    end

    test "development backfill permits actor profile after cluster reaches layer1" do
      with_pipeline_mode do
        snapshot =
          base_snapshot.deep_merge(
            layer1: {
              lag: 5,
              checkpoint_available: true
            },

            cluster: {
              lag: 0,
              global_lag: 5,
              checkpoint_available: true,
              caught_up_to_layer1: true
            },

            actor_profile: {
              pending_work: 406_000,
              processing: false
            }
          )

        decision =
          PipelineController.decision(
            :actor_profile,
            current_snapshot: snapshot
          )

        assert decision[:allowed]
        assert_empty decision[:failed_constraints]
      end
    end

    test "concurrent ssd makes lag one available to layer1" do
      with_pipeline_mode(strict_io_mode: "concurrent_ssd") do
        snapshot =
          base_snapshot.deep_merge(
            layer1: {
              lag: 1,
              processing: false,
              strict_queue_size: 0,
              strict_worker_busy: false
            }
          )

        decision =
          PipelineController.decision(
            :layer1_realtime,
            current_snapshot: snapshot
          )

        assert PipelineController.work_available?(decision)
      end
    end

    test "concurrent ssd lets cluster consume certified checkpoint while layer1 is active" do
      with_pipeline_mode(strict_io_mode: "concurrent_ssd") do
        snapshot =
          base_snapshot.deep_merge(
            development_backfill: {
              enabled: true,
              phase: "layer1_catchup"
            },
            layer1: {
              processing: true,
              strict_queue_size: 1,
              strict_worker_busy: true,
              buffers_empty: true,
              checkpoint_available: true
            },
            cluster: {
              lag: 2,
              processing: false,
              strict_queue_size: 0,
              strict_worker_busy: false
            },
            strict_io: {
              owner: "layer1",
              owners: ["layer1"]
            }
          )

        decision =
          PipelineController.decision(
            :cluster,
            current_snapshot: snapshot
          )

        assert decision[:allowed]
        assert_empty decision[:failed_constraints]
        assert PipelineController.work_available?(decision)
        assert_includes decision[:constraints], :layer1_buffers_empty
        refute_includes decision[:constraints], :layer1_not_processing
        refute_includes decision[:constraints], :layer1_strict_worker_idle
        refute_includes decision[:constraints], :strict_io_not_layer1
      end
    end

    test "concurrent ssd keeps the layer1 buffer guard for cluster" do
      with_pipeline_mode(strict_io_mode: "concurrent_ssd") do
        snapshot =
          base_snapshot.deep_merge(
            layer1: {
              processing: true,
              buffers_empty: false,
              strict_worker_busy: true
            },
            cluster: {
              lag: 2
            }
          )

        decision =
          PipelineController.decision(
            :cluster,
            current_snapshot: snapshot
          )

        refute decision[:allowed]
        assert_includes decision[:failed_constraints], :layer1_buffers_empty
      end
    end

    test "snapshot exposes both concurrent owners and keeps legacy owner field" do
      with_pipeline_mode(strict_io_mode: "concurrent_ssd") do
        now = Time.current
        leases =
          %w[layer1 cluster].map do |owner|
            StrictPipeline::StrictIoLease::Lease.new(
              owner: owner,
              token: "#{owner}-token",
              acquired_at: now,
              expires_at: now + 5.minutes
            )
          end

        rpc = Struct.new(:getblockcount).new(956_761)

        StrictPipeline::StrictIoLease.stub(:currents, leases) do
          BitcoinRpc.stub(:new, rpc) do
            snapshot = PipelineController.snapshot

            refute snapshot[:error], snapshot[:error]
            assert_equal %w[layer1 cluster], snapshot.dig(:strict_io, :owners)
            assert_equal "layer1", snapshot.dig(:strict_io, :owner)
            assert_equal leases.first.acquired_at.iso8601(6),
              snapshot.dig(:strict_io, :acquired_at)
          end
        end
      end
    end

    private

    def base_snapshot
      {
        bitcoin_core: {
          available: true,
          best_height: 956_761
        },

        layer1: {
          processed_height: 956_760,
          checkpoint_available: true,
          lag: 1,
          processing: false,
          buffers_empty: true,
          buffers: {
            outputs: 0,
            spent: 0
          },
          strict_queue_size: 0,
          strict_worker_busy: false
        },

        cluster: {
          processed_height: 956_744,
          checkpoint_available: true,
          lag: 16,
          global_lag: 17,
          processing: false,
          strict_queue_size: 0,
          strict_worker_busy: false
        },

        address_spend_projection: {
          available: true,
          source_available: true,
          worker_present: true,
          checkpoint_height: 956_250,
          checkpoint_available: true,
          caught_up_to_cluster: true,
          lag: 0,
          next_record_height: nil,
          work_available: false,
          processing: false,
          strict_queue_size: 0,
          strict_worker_busy: false,
          strict_active: false,
          failed: false,
          status: "healthy"
        },

        actor_profile: {
          checkpoint_available: true,
          pending_work: 405_476,
          processing: false,
          caught_up_to_cluster: false,
          strict_queue_size: 0,
          strict_worker_busy: false
        },

        strict_io: {
          owner: nil
        }
      }
    end

    def with_pipeline_mode(
      mode = "development_backfill",
      strict_io_mode: "serialized"
    )
      keys = {
        "TANSA_PIPELINE_MODE" => mode,
        "TANSA_STRICT_IO_MODE" => strict_io_mode,
        "TANSA_BACKFILL_MAX_LAYER1_LAG" => "20",
        "TANSA_BACKFILL_MAX_CLUSTER_GLOBAL_LAG" => "30"
      }

      previous =
        keys.keys.to_h do |key|
          [
            key,
            ENV.key?(key) ? ENV[key] : :missing
          ]
        end

      keys.each do |key, value|
        ENV[key] = value
      end

      yield
    ensure
      previous.each do |key, value|
        if value == :missing
          ENV.delete(key)
        else
          ENV[key] = value
        end
      end
    end
  end
end
