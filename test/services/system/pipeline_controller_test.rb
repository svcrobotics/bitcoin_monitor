# frozen_string_literal: true

require "test_helper"

module System
  class PipelineControllerTest < ActiveSupport::TestCase
    STRICT_ROLES = %i[
      layer1_realtime
      cluster
      address_spend_projection
      actor_profile
      actor_labels
    ].freeze

    HEAVY_ROLES = %i[
      layer1_audit
      tx_outputs_async
      tx_output_projection
    ].freeze

    test "layer1 realtime is independent from downstream and heavy states" do
      snapshot =
        stable_snapshot.deep_merge(
          cluster: {
            processing: true,
            strict_queue_size: 12,
            strict_worker_busy: true,
            caught_up_to_layer1: false
          },
          actor_profile: {
            processing: true,
            strict_queue_size: 4,
            strict_worker_busy: true,
            pending_work: 20,
            caught_up_to_cluster: false
          },
          actor_labels: {
            strict_queue_size: 5,
            strict_worker_busy: true
          },
          historical_projection: {
            status: "failed",
            projection_lag_blocks: 1_000
          }
        )

      decision =
        PipelineController.decision(
          :layer1_realtime,
          current_snapshot: snapshot
        )

      assert decision[:allowed]
      assert_equal :layer1_realtime, decision[:module]
      assert_equal :source_of_truth, decision[:architecture_role]
    end

    test "audit backlog does not block layer1 realtime" do
      with_stubbed(
        Layer1::Audit::OperationalSnapshot,
        :call,
        -> { raise "audit snapshot must not be called" }
      ) do
        assert_allowed(:layer1_realtime)
      end
    end

    test "tx outputs spent sync backlog does not block layer1 realtime" do
      with_stubbed(
        Layer1::TxOutputsSpentSync::OperationalSnapshot,
        :call,
        -> { raise "projection snapshot must not be called" }
      ) do
        assert_allowed(:layer1_realtime)
      end
    end

    test "tx output projection backlog does not block layer1 realtime" do
      snapshot =
        stable_snapshot.deep_merge(
          tx_output_projection: {
            status: "failed",
            pending_count: 100
          }
        )

      assert_allowed(:layer1_realtime, snapshot: snapshot)
    end

    test "cluster can run while layer1 lag remains within budget" do
      decision =
        decision_for(
          :cluster,
          stable_snapshot.deep_merge(
            layer1: {
              lag: 2,
              catching_up: true,
              processing: false,
              buffers_empty: true,
              strict_queue_size: 0,
              strict_worker_busy: false
            }
          )
        )

      assert decision[:allowed]
      assert_empty decision[:failed_constraints]
    end

    test "cluster is refused when layer1 lag exceeds budget" do
      decision =
        decision_for(
          :cluster,
          stable_snapshot.deep_merge(
            layer1: {
              lag: 4,
              catching_up: true,
              processing: false,
              buffers_empty: true,
              strict_queue_size: 0,
              strict_worker_busy: false
            }
          )
        )

      refute decision[:allowed]

      assert_includes(
        decision[:failed_constraints],
        :cluster_layer1_lag_within_budget
      )

      assert_equal :cluster_layer1_lag_within_budget, decision[:reason]
    end

    test "cluster is refused while layer1 processes within lag budget" do
      decision =
        decision_for(
          :cluster,
          stable_snapshot.deep_merge(
            layer1: {
              lag: 2,
              processing: true,
              catching_up: true
            }
          )
        )

      refute decision[:allowed]
      assert_includes decision[:failed_constraints], :layer1_not_processing
    end
    test "cluster is refused while layer1 buffers are active within lag budget" do
      decision =
        decision_for(
          :cluster,
          stable_snapshot.deep_merge(
            layer1: {
              lag: 2,
              buffers_empty: false
            }
          )
        )

      refute decision[:allowed]
      assert_includes decision[:failed_constraints], :layer1_buffers_empty
    end
    test "cluster is refused while layer1 strict queue is active within lag budget" do
      decision =
        decision_for(
          :cluster,
          stable_snapshot.deep_merge(
            layer1: {
              lag: 2,
              strict_queue_size: 1
            }
          )
        )

      refute decision[:allowed]
      assert_includes decision[:failed_constraints], :layer1_strict_queue_idle
    end
    test "cluster is refused while layer1 strict worker is busy within lag budget" do
      decision =
        decision_for(
          :cluster,
          stable_snapshot.deep_merge(
            layer1: {
              lag: 2,
              strict_worker_busy: true
            }
          )
        )

      refute decision[:allowed]
      assert_includes decision[:failed_constraints], :layer1_strict_worker_idle
    end

    test "cluster is refused while strict io lease belongs to layer1" do
      decision =
        decision_for(
          :cluster,
          stable_snapshot.deep_merge(
            strict_io: {
              owner: "layer1"
            }
          )
        )

      refute decision[:allowed]
      assert_includes decision[:failed_constraints], :strict_io_not_layer1
    end
    test "cluster is allowed when layer1 is stable" do
      assert_allowed(:cluster)
    end

    test "single new bitcoin core tip without layer1 activity does not block cluster" do
      snapshot =
        stable_snapshot.deep_merge(
          bitcoin_core: {
            best_height: 956_251
          },
          layer1: {
            lag: 1,
            catching_up: false,
            processing: false,
            buffers_empty: true,
            strict_queue_size: 0,
            strict_worker_busy: false
          }
        )

      assert_allowed(:cluster, snapshot: snapshot)
    end

    test "actor profile can run while cluster is not perfectly caught up" do
      decision =
        decision_for(
          :actor_profile,
          stable_snapshot.deep_merge(
            cluster: {
              global_lag: 1,
              caught_up_to_layer1: false
            }
          )
        )

      assert decision[:allowed]
      assert_empty decision[:failed_constraints]
    end

    test "actor profile can run while cluster processes within budget" do
      decision =
        decision_for(
          :actor_profile,
          stable_snapshot.deep_merge(
            cluster: {
              processing: true,
              global_lag: 1
            }
          )
        )

      assert decision[:allowed]
      assert_empty decision[:failed_constraints]
    end

    test "actor profile can run with cluster backlog within budget" do
      decision =
        decision_for(
          :actor_profile,
          stable_snapshot.deep_merge(
            cluster: {
              lag: 3,
              global_lag: 3,
              caught_up_to_layer1: false
            }
          )
        )

      assert decision[:allowed]
      assert_empty decision[:failed_constraints]
    end

    test "actor profile can run from certified cluster checkpoint while layer1 is ahead" do
      decision =
        decision_for(
          :actor_profile,
          stable_snapshot.deep_merge(
            layer1: {
              processed_height: 957_820,
              lag: 0
            },

            cluster: {
              processed_height: 957_815,
              lag: 5,
              global_lag: 5,
              caught_up_to_layer1: false
            }
          )
        )

      assert decision[:allowed]
      assert_empty decision[:failed_constraints]
    end

    test "actor labels waits for actor profile" do
      decision =
        decision_for(
          :actor_labels,
          actor_labels_ready_snapshot.deep_merge(
            actor_profile: {
              pending_work: 10,
              caught_up_to_cluster: false
            }
          )
        )

      refute decision[:allowed]
      assert_equal :actor_profile_priority, decision[:reason]
    end

    test "actor labels is refused when actor profile is working" do
      decision =
        decision_for(
          :actor_labels,
          actor_labels_ready_snapshot.deep_merge(
            actor_profile: {
              processing: true,
              strict_worker_busy: true
            }
          )
        )

      refute decision[:allowed]
      assert_includes decision[:failed_constraints], :actor_profile_not_processing
    end

    test "heavy backlog does not block cluster actor profile or actor labels" do
      snapshot =
        stable_snapshot.deep_merge(
          historical_projection: {
            status: "failed",
            pending_count: 100
          }
        )

      %i[cluster actor_profile].each do |role|
        assert_allowed(role, snapshot: snapshot)
      end

      assert_allowed(
        :actor_labels,
        snapshot: actor_labels_ready_snapshot(snapshot)
      )
    end

    test "historical projection uses bounded realtime lag budgets" do
      acceptable_backlog =
        stable_snapshot.deep_merge(
          layer1: {
            lag: 5,
            processing: false,
            catching_up: false
          },

          cluster: {
            lag: 2,
            processing: false,
            caught_up_to_layer1: false
          },

          actor_profile: {
            pending_work: 100_000,
            caught_up_to_cluster: false
          }
        )

      %i[
        tx_outputs_async
        tx_output_projection
      ].each do |role|
        assert(
          decision_for(role, acceptable_backlog)[:allowed],
          "#{role} unexpectedly denied"
        )
      end

      layer1_over_budget =
        acceptable_backlog.deep_merge(
          layer1: {
            lag: 7
          }
        )

      %i[
        tx_outputs_async
        tx_output_projection
      ].each do |role|
        decision =
          decision_for(
            role,
            layer1_over_budget
          )

        refute decision[:allowed]

        assert_includes(
          decision[:failed_constraints],
          :historical_layer1_lag_within_budget
        )
      end

      cluster_over_budget =
        acceptable_backlog.deep_merge(
          cluster: {
            lag: 13
          }
        )

      %i[
        tx_outputs_async
        tx_output_projection
      ].each do |role|
        decision =
          decision_for(
            role,
            cluster_over_budget
          )

        refute decision[:allowed]

        assert_includes(
          decision[:failed_constraints],
          :historical_cluster_lag_within_budget
        )
      end

      buffers_busy =
        acceptable_backlog.deep_merge(
          layer1: {
            buffers_empty: false,
            buffers: {
              outputs: 1,
              spent: 0
            }
          }
        )

      %i[
        tx_outputs_async
        tx_output_projection
      ].each do |role|
        decision =
          decision_for(
            role,
            buffers_busy
          )

        assert decision[:allowed]
        assert_empty decision[:failed_constraints]
      end

      refute(
        decision_for(
          :layer1_audit,
          acceptable_backlog
        )[:allowed]
      )

      refute(
        decision_for(
          :coverage,
          acceptable_backlog
        )[:allowed]
      )
    end

    test "historical and heavy roles are refused while strict io lease is held" do
      snapshot =
        stable_snapshot.deep_merge(
          strict_io: {
            owner: "cluster"
          }
        )

      %i[
        layer1_audit
        tx_outputs_async
        tx_output_projection
        coverage
      ].each do |role|
        decision =
          decision_for(role, snapshot)

        refute decision[:allowed], "#{role} unexpectedly allowed"
        assert_includes decision[:failed_constraints], :strict_io_idle
      end
    end

    test "coverage is refused while a strict stage has priority" do
      snapshots = [
        stable_snapshot.deep_merge(layer1: { strict_queue_size: 1, catching_up: true }),
        stable_snapshot.deep_merge(cluster: { strict_queue_size: 1 }),
        stable_snapshot.deep_merge(actor_profile: { strict_queue_size: 1 })
      ]

      snapshots.each do |snapshot|
        refute decision_for(:coverage, snapshot)[:allowed]
      end
    end

    test "legacy layer1 role aliases layer1 realtime exactly" do
      assert_equal(
        decision_for(:layer1_realtime, stable_snapshot),
        decision_for(:layer1, stable_snapshot)
      )
    end

    test "realtime decision does not build audit or historical snapshots" do
      with_stubbed(
        Layer1::Audit::OperationalSnapshot,
        :call,
        -> { raise "audit snapshot must not be called" }
      ) do
        with_stubbed(
          Layer1::TxOutputsSpentSync::OperationalSnapshot,
          :call,
          -> { raise "projection snapshot must not be called" }
        ) do
          assert_allowed(:layer1_realtime)
        end
      end
    end

    test "permissive layer1 lag constants are removed" do
      refute System::PipelineController.const_defined?(:MAX_LAYER1_LAG_FOR_CLUSTER)
      refute System::PipelineController.const_defined?(:MAX_LAYER1_LAG_FOR_ACTOR_PROFILE)
    end

    test "cluster and actor profile authorization do not use arbitrary numeric lag thresholds" do
      source =
        Rails.root.join(
          "app/services/system/pipeline_controller.rb"
        ).read

      refute_match(/MAX_LAYER1_LAG_FOR_CLUSTER/, source)
      refute_match(/MAX_LAYER1_LAG_FOR_ACTOR_PROFILE/, source)
      refute_match(/synced_for_cluster/, source)
      refute_match(/synced_for_actor_profile/, source)
      refute_match(/lag\)\.to_i\s*[<]=\s*\d+/, source)
      refute_match(/lag\]\.to_i\s*[<]=\s*\d+/, source)
    end

    test "decision exposes canonical module and separate architecture role" do
      decision = decision_for(:cluster, stable_snapshot)

      assert_equal :cluster, decision[:module]
      assert_equal :identity_layer, decision[:architecture_role]
      assert_equal :identity_layer, decision[:role]
    end

    test "all declared roles have explicit work availability behavior" do
      roles =
        System::PipelineController::PIPELINE_REGISTRY.keys

      roles.each do |role|
        decision = decision_for(role, stable_snapshot)

        assert_includes [true, false], System::PipelineController.work_available?(decision)
      end
    end

    test "actor behavior role is recognized" do
      assert_includes(
        System::PipelineController::PIPELINE_REGISTRY.keys,
        :actor_behavior
      )
    end

    test "actor behavior disabled when flag is disabled" do
      with_actor_behavior_control(
        auto_enabled: false,
        certified_profiles_available: true,
        work_available: true,
        missing_work_available: true
      ) do
        decision =
          decision_for(:actor_behavior, stable_snapshot)

        refute decision[:allowed]
        assert_equal :disabled, decision[:state]
        assert_equal :actor_behavior_auto_disabled, decision[:reason]
      end
    end

    test "actor behavior blocked without certified profiles" do
      with_actor_behavior_control(
        auto_enabled: true,
        certified_profiles_available: false
      ) do
        decision =
          decision_for(:actor_behavior, stable_snapshot)

        refute decision[:allowed]
        assert_equal :blocked, decision[:state]
        assert_equal :no_certified_actor_profiles, decision[:reason]
      end
    end

    test "actor behavior blocked when actor profile dependency is invalid" do
      with_actor_behavior_control(
        auto_enabled: true,
        certified_profiles_available: true,
        work_available: true,
        missing_work_available: true
      ) do
        decision =
          decision_for(
            :actor_behavior,
            stable_snapshot.deep_merge(
              actor_profile: {
                checkpoint_available: false
              }
            )
          )

        refute decision[:allowed]
        assert_equal :blocked, decision[:state]
        assert_equal :actor_profile_unavailable, decision[:reason]
      end
    end

    test "actor behavior can work while actor profile backlog remains" do
      with_actor_behavior_control(
        auto_enabled: true,
        certified_profiles_available: true,
        work_available: true,
        missing_work_available: true
      ) do
        decision =
          decision_for(
            :actor_behavior,
            stable_snapshot.deep_merge(
              actor_profile: {
                pending_work: 10,
                caught_up_to_cluster: false
              }
            )
          )

        assert decision[:allowed]
        assert_equal :run, decision[:state]
      end
    end

    test "actor behavior is refused while layer1 lag is critical" do
      with_actor_behavior_control(
        auto_enabled: true,
        certified_profiles_available: true,
        work_available: true,
        missing_work_available: true
      ) do
        decision =
          decision_for(
            :actor_behavior,
            stable_snapshot.deep_merge(
              layer1: {
                lag: Layer1::HistoricalWorkConfig.max_layer1_lag_blocks + 1,
                catching_up: true
              }
            )
          )

        refute decision[:allowed]
        assert_equal :blocked, decision[:state]
        assert_equal :layer1_realtime_priority, decision[:reason]
        assert_includes(
          decision[:failed_constraints],
          :layer1_not_catching_up
        )
      end
    end

    test "actor behavior is refused while layer1 is processing" do
      with_actor_behavior_control(
        auto_enabled: true,
        certified_profiles_available: true,
        work_available: true,
        missing_work_available: true
      ) do
        decision =
          decision_for(
            :actor_behavior,
            stable_snapshot.deep_merge(
              layer1: {
                processing: true,
                processing_height: 956_251,
                catching_up: true
              }
            )
          )

        refute decision[:allowed]
        assert_equal :layer1_realtime_priority, decision[:reason]
        assert_includes(
          decision[:failed_constraints],
          :layer1_not_processing
        )
      end
    end

    test "actor behavior runs when missing work is available" do
      with_actor_behavior_control(
        auto_enabled: true,
        certified_profiles_available: true,
        work_available: true,
        missing_work_available: true,
        stale_work_available: false
      ) do
        decision =
          decision_for(:actor_behavior, stable_snapshot)

        assert decision[:allowed]
        assert_equal :run, decision[:state]
        assert_equal :actor_behavior_work_available, decision[:reason]
        assert decision.dig(:actor_behavior, :missing_work_available)
      end
    end

    test "actor behavior can run again when layer1 and cluster are stable" do
      with_actor_behavior_control(
        auto_enabled: true,
        certified_profiles_available: true,
        work_available: true,
        missing_work_available: true,
        cooldown_active: false
      ) do
        decision =
          decision_for(:actor_behavior, stable_snapshot)

        assert decision[:allowed]
        assert_equal :run, decision[:state]
        assert_equal :actor_behavior_work_available, decision[:reason]
      end
    end

    test "actor behavior runs when stale work is available" do
      with_actor_behavior_control(
        auto_enabled: true,
        certified_profiles_available: true,
        work_available: true,
        missing_work_available: false,
        stale_work_available: true
      ) do
        decision =
          decision_for(:actor_behavior, stable_snapshot)

        assert decision[:allowed]
        assert_equal :run, decision[:state]
        assert decision.dig(:actor_behavior, :stale_work_available)
      end
    end

    test "actor behavior idles when no work is available" do
      with_actor_behavior_control(
        auto_enabled: true,
        certified_profiles_available: true,
        work_available: false
      ) do
        decision =
          decision_for(:actor_behavior, stable_snapshot)

        assert decision[:allowed]
        assert_equal :idle, decision[:state]
        assert_equal :no_actor_behavior_work, decision[:reason]
        refute System::PipelineController.work_available?(decision)
      end
    end

    test "actor behavior blocked while batch is already running" do
      with_actor_behavior_control(
        auto_enabled: true,
        certified_profiles_available: true,
        work_available: true,
        batch_running: true
      ) do
        decision =
          decision_for(:actor_behavior, stable_snapshot)

        refute decision[:allowed]
        assert_equal :blocked, decision[:state]
        assert_equal :actor_behavior_batch_running, decision[:reason]
      end
    end

    test "actor behavior blocked on stale running run" do
      with_actor_behavior_control(
        auto_enabled: true,
        certified_profiles_available: true,
        work_available: true,
        stale_running_run: true
      ) do
        decision =
          decision_for(:actor_behavior, stable_snapshot)

        refute decision[:allowed]
        assert_equal :blocked, decision[:state]
        assert_equal :stale_actor_behavior_run, decision[:reason]
      end
    end

    test "actor behavior decision never consults actor labels" do
      with_actor_behavior_control(
        auto_enabled: true,
        certified_profiles_available: true,
        work_available: true,
        missing_work_available: true
      ) do
        with_stubbed(
          System::PipelineController,
          :actor_labels_snapshot,
          -> { raise "actor labels must not be consulted" }
        ) do
          assert_nothing_raised do
            System::PipelineController.decision(:actor_behavior)
          end
        end
      end
    end

    test "actor behavior decision does not use heavy behavior snapshots" do
      with_actor_behavior_control(
        auto_enabled: true,
        certified_profiles_available: true,
        work_available: true,
        missing_work_available: true
      ) do
        with_stubbed(
          ActorBehaviors::OperationalSnapshot,
          :call,
          -> { raise "operational snapshot must not be called" }
        ) do
          with_stubbed(
            ActorBehaviors::StrictHealthSnapshot,
            :call,
            -> { raise "strict health must not be called" }
          ) do
            assert_nothing_raised do
              decision_for(:actor_behavior, stable_snapshot)
            end
          end
        end
      end
    end

    test "actor behavior exposes stable machine readable reasons" do
      with_actor_behavior_control(
        auto_enabled: true,
        certified_profiles_available: false
      ) do
        decision =
          decision_for(:actor_behavior, stable_snapshot)

        assert_equal :no_certified_actor_profiles, decision[:reason]
        assert_includes(
          decision[:failed_constraints],
          :certified_actor_profiles_available
        )
      end
    end

    test "actor behavior decision has no side effects" do
      with_actor_behavior_control(
        auto_enabled: true,
        certified_profiles_available: true,
        work_available: true,
        missing_work_available: true
      ) do
        assert_no_difference -> { ActorBehaviorRun.count } do
          assert_no_difference -> { ActorBehaviorSnapshot.count } do
            decision_for(:actor_behavior, stable_snapshot)
          end
        end
      end
    end

    test "actor labels are refused while layer1 is critical" do
      decision =
        decision_for(
          :actor_labels,
          actor_labels_ready_snapshot.deep_merge(
            layer1: {
              processing: true,
              processing_height: 956_251,
              catching_up: true
            }
          )
        )

      refute decision[:allowed]
      assert_equal :blocked, decision[:state]
      assert_equal :layer1_realtime_priority, decision[:reason]
    end

    test "next module does not select scheduler only layer1 audit" do
      snapshot =
        stable_snapshot.deep_merge(
          layer1: {
            lag: 0
          },
          cluster: {
            lag: 0
          }
        )

      with_stubbed(System::PipelineController, :snapshot, snapshot) do
        refute_equal :layer1_audit, System::PipelineController.next_module&.dig(:module)
      end
    end

    test "runtime priority scenarios match expected allowed states" do
      assert_allowed_states(
        stable_snapshot.deep_merge(
          layer1: {
            lag: 7,
            processing: true,
            catching_up: true
          }
        ),
        layer1_realtime: true,
        cluster: false,
        actor_profile: false,
        actor_labels: false,
        layer1_audit: false,
        tx_outputs_async: false,
        tx_output_projection: false,
        coverage: false
      )

      assert_allowed_states(
        stable_snapshot.deep_merge(
          cluster: {
            lag: 1,
            global_lag: 1,
            caught_up_to_layer1: false
          }
        ),
        layer1_realtime: true,
        cluster: true,
        actor_profile: true,
        actor_labels: false,
        layer1_audit: false,
        tx_outputs_async: true,
        tx_output_projection: true,
        coverage: false
      )

      assert_allowed_states(
        stable_snapshot.deep_merge(
          actor_profile: {
            pending_work: 2,
            caught_up_to_cluster: false
          }
        ),
        layer1_realtime: true,
        cluster: true,
        actor_profile: true,
        actor_labels: false,
        layer1_audit: false,
        tx_outputs_async: true,
        tx_output_projection: true,
        coverage: false
      )

      assert_allowed_states(
        actor_labels_ready_snapshot,
        layer1_realtime: true,
        cluster: true,
        actor_profile: true,
        actor_labels: true,
        layer1_audit: true,
        tx_outputs_async: true,
        tx_output_projection: true,
        coverage: true
      )
    end

    private

    def assert_allowed(role, snapshot: stable_snapshot)
      decision = decision_for(role, snapshot)

      assert decision[:allowed], "#{role} denied: #{decision.inspect}"
    end

    def decision_for(role, snapshot)
      PipelineController.decision(
        role,
        current_snapshot: snapshot
      )
    end

    def assert_allowed_states(snapshot, expectations)
      expectations.each do |role, allowed|
        decision = decision_for(role, snapshot)

        assert_equal allowed, decision[:allowed], "#{role}: #{decision.inspect}"
      end
    end

    def with_stubbed(object, method_name, value = nil)
      original = object.method(method_name)
      replacement =
        if value.respond_to?(:call)
          value
        else
          ->(*_args, **_kwargs) { value }
        end

      object.define_singleton_method(method_name, &replacement)

      yield
    ensure
      object.define_singleton_method(method_name) do |*args, **kwargs, &block|
        original.call(*args, **kwargs, &block)
      end
    end

    def with_actor_behavior_control(**overrides)
      with_stubbed(
        ActorBehaviors::ControlSnapshot,
        :call,
        actor_behavior_control(**overrides)
      ) do
        yield
      end
    end

    def actor_behavior_control(**overrides)
      {
        mode: "shadow",
        auto_enabled: false,
        behavior_version: "strict_v2",
        certified_profiles_available: false,
        work_available: false,
        missing_work_available: false,
        stale_work_available: false,
        batch_running: false,
        stale_running_run: false,
        last_run_status: nil,
        last_run_finished_at: nil,
        generated_at: Time.current
      }.merge(overrides)
    end

    def actor_labels_ready_snapshot(base = stable_snapshot)
      base.deep_merge(
        actor_behavior: actor_behavior_control(
          auto_enabled: true,
          behavior_version: "strict_v2",
          certified_profiles_available: true,
          work_available: false
        ),
        actor_labels: {
          source: ActorLabels::StrictRuleSet::SOURCE,
          rule_version: ActorLabels::StrictRuleSet::RULE_VERSION,
          required_behavior_version: "strict_v2",
          queue_name: "actor_labels_strict",
          queue_size: 0,
          scheduled_size: 0,
          worker_busy: false,
          worker_present: true,
          lock_present: false,
          cursor: 0,
          work_available: true,
          pending_for_labels: 25,
          cooldown_active: false,
          cooldown_remaining_seconds: 0,
          next_eligible_at: nil,
          last_run_status: "completed",
          last_run_finished_at: Time.current,
          last_runtime_ms: 10
        }
      )
    end

    def stable_snapshot
      {
        bitcoin_core: {
          available: true,
          best_height: 956_250,
          error: nil
        },
        layer1: {
          processed_height: 956_250,
          lag: 0,
          processing: false,
          processing_height: nil,
          buffers: {
            outputs: 0,
            spent: 0
          },
          buffers_empty: true,
          idle: true,
          strict_queue_size: 0,
          strict_worker_busy: false,
          strict_active: false,
          checkpoint_available: true,
          catching_up: false
        },
        cluster: {
          processed_height: 956_250,
          lag: 0,
          processing: false,
          processing_height: nil,
          idle: true,
          strict_queue_size: 0,
          strict_worker_busy: false,
          checkpoint_available: true,
          caught_up_to_layer1: true
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
          checkpoint_height: 956_250,
          checkpoint_available: true,
          caught_up_to_cluster: true,
          pending_work: 0,
          processing: false,
          strict_queue_size: 0,
          strict_worker_busy: false,
          strict_active: false
        },
        actor_labels: {
          checkpoint_available: true,
          processing: false,
          strict_queue_size: 0,
          strict_worker_busy: false,
          scheduled_marker_present: false,
          strict_active: false
        },
        strict_io: {
          owner: nil,
          acquired_at: nil,
          expires_at: nil
        }
      }
    end
  end
end
