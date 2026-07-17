# frozen_string_literal: true

require "test_helper"

module System
  class AnomalySnapshotTest < ActiveSupport::TestCase
    test "returns no anomaly when all reusable snapshots are nominal" do
      with_nominal_snapshots do
        snapshot =
          System::AnomalySnapshot.call

        assert_nil snapshot[:overall_severity]
        assert_equal [], snapshot[:anomalies]
      end
    end

    test "returns a critical anomaly for bitcoin core unavailability" do
      with_nominal_snapshots(
        pipeline: stable_pipeline.deep_merge(
          bitcoin_core: {
            available: false,
            error: "rpc timeout"
          }
        )
      ) do
        snapshot =
          System::AnomalySnapshot.call

        assert_equal "critical", snapshot[:overall_severity]
        assert_equal ["bitcoin_core_unavailable"], snapshot[:anomalies].map { |a| a[:code] }
        assert_equal "infrastructure:bitcoin_core_unavailable", snapshot[:anomalies].first[:fingerprint]
      end
    end

    test "isolates an exception in one rule" do
      bad_rule =
        Module.new do
          def self.name = "BadRule"
          def self.call(context:) = raise "boom"
        end

      original =
        System::AnomalySnapshot::RULES

      System::AnomalySnapshot.send(:remove_const, :RULES)
      System::AnomalySnapshot.const_set(:RULES, [bad_rule])

      snapshot =
        System::AnomalySnapshot.call

      assert_equal "warning", snapshot[:overall_severity]
      assert_equal "anomaly_rule_failed", snapshot[:anomalies].first[:code]
    ensure
      System::AnomalySnapshot.send(:remove_const, :RULES)
      System::AnomalySnapshot.const_set(:RULES, original)
    end

    test "does not write business data" do
      with_nominal_snapshots do
        assert_no_difference -> { ActorLabel.count } do
          assert_no_difference -> { ActorProfile.count } do
            System::AnomalySnapshot.call
          end
        end
      end
    end

    private

    def with_nominal_snapshots(
      pipeline: stable_pipeline,
      layer1: { status: "healthy", lag: 0, strict: {} },
      cluster: { status: "healthy", issues: [] },
      behavior: actor_behavior_control,
      labels: actor_labels_control,
      sidekiq: sidekiq_snapshot
    )
      with_stubbed(System::PipelineController, :snapshot, pipeline) do
        with_stubbed(System::PipelineController, :decision, ->(role, current_snapshot: nil) {
          {
            module: role,
            allowed: true,
            state: :idle,
            reason: nil,
            failed_constraints: [],
            snapshot: current_snapshot
          }
        }) do
          with_stubbed(Layer1::Realtime::HealthSnapshot, :call, layer1) do
            with_stubbed(Clusters::StrictHealthSnapshot, :call, cluster) do
              with_stubbed(ActorBehaviors::ControlSnapshot, :call, behavior) do
                with_stubbed(ActorLabels::ControlSnapshot, :call, labels) do
                  with_stubbed(System::Anomalies::SidekiqSnapshot, :call, sidekiq) do
                    yield
                  end
                end
              end
            end
          end
        end
      end
    end

    def stable_pipeline
      {
        bitcoin_core: {
          available: true,
          best_height: 100
        },
        layer1: {
          processed_height: 100,
          lag: 0,
          processing: false,
          processing_height: nil,
          buffers_empty: true,
          strict_queue_size: 0,
          strict_worker_busy: false,
          checkpoint_available: true,
          catching_up: false
        },
        cluster: {
          processed_height: 100,
          lag: 0,
          processing: false,
          strict_queue_size: 0,
          strict_worker_busy: false,
          checkpoint_available: true,
          caught_up_to_layer1: true
        },
        actor_profile: {
          checkpoint_height: 100,
          checkpoint_available: true,
          caught_up_to_cluster: true,
          pending_work: 0,
          processing: false,
          strict_queue_size: 0,
          strict_worker_busy: false
        },
        actor_labels: {
          strict_queue_size: 0,
          strict_worker_busy: false
        }
      }
    end

    def actor_behavior_control
      {
        auto_enabled: true,
        work_available: false,
        batch_running: false,
        stale_running_run: false,
        cooldown_active: false,
        certified_profiles_available: true
      }
    end

    def actor_labels_control
      {
        worker_present: true,
        worker_write_observed: true,
        worker_write_status_fresh: true,
        worker_write_enabled: true,
        queue_name: "actor_labels_strict",
        queue_size: 0,
        scheduled_size: 0,
        worker_busy: false,
        lock_present: false,
        work_available: false
      }
    end

    def sidekiq_snapshot
      {
        queue_processes:
          System::Anomalies::SidekiqSnapshot::EXPECTED_QUEUES.index_with { 1 },
        queues:
          System::Anomalies::SidekiqSnapshot::EXPECTED_QUEUES.index_with do
            {
              size: 0,
              latency: 0
            }
          end,
        retries: 0,
        dead: 0
      }
    end

    def with_stubbed(object, method_name, value)
      original =
        object.method(method_name)

      object.define_singleton_method(method_name) do |*args, **kwargs|
        value.respond_to?(:call) ? value.call(*args, **kwargs) : value
      end

      yield
    ensure
      object.define_singleton_method(method_name) do |*args, **kwargs, &block|
        original.call(*args, **kwargs, &block)
      end
    end
  end
end
