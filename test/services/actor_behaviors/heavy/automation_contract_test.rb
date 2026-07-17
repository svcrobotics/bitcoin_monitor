# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

module ActorBehaviors
  module Heavy
    class AutomationContractTest <
      ActiveSupport::TestCase

      setup do
        Sidekiq.redis do |redis|
          redis.del(
            ControlSnapshot::
              LAST_ENQUEUED_KEY
          )
        end
      end

      teardown do
        Sidekiq.redis do |redis|
          redis.del(
            ControlSnapshot::
              LAST_ENQUEUED_KEY
          )
        end
      end

      test "control is disabled by default" do
        with_env(
          "ACTOR_BEHAVIOR_HEAVY_AUTO_ENABLED" =>
            nil,

          "ACTOR_BEHAVIOR_HEAVY_LABELS_ENABLED" =>
            nil
        ) do
          result =
            ControlSnapshot.call(
              current_snapshot:
                base_snapshot
            )

          refute result[:auto_enabled]
          refute result[:labels_enabled]
          refute result[:work_available]
        end
      end

      test "control exposes one automatic candidate" do
        candidate =
          Struct.new(
            :id,
            :cluster_id
          ).new(
            123,
            29_499
          )

        with_env(
          "ACTOR_BEHAVIOR_HEAVY_AUTO_ENABLED" =>
            "true",

          "ACTOR_BEHAVIOR_HEAVY_LABELS_ENABLED" =>
            "true"
        ) do
          CandidateScope.stub(
            :call,
            [candidate]
          ) do
            result =
              ControlSnapshot.call(
                current_snapshot:
                  base_snapshot
              )

            assert result[:auto_enabled]
            assert result[:labels_enabled]
            assert result[:work_available]

            assert_equal(
              123,
              result[:candidate_snapshot_id]
            )

            assert_equal(
              29_499,
              result[:candidate_cluster_id]
            )
          end
        end
      end

      test "pipeline controller runs Heavy only after strict behavior" do
        control = {
          status: "active",
          auto_enabled: true,
          labels_enabled: true,
          cooldown_active: false,
          cooldown_remaining_seconds: 0,
          work_available: true,
          candidate_cluster_id: 29_499
        }

        strict_behavior = {
          state: :idle,

          actor_behavior: {
            work_available: false,
            batch_running: false,
            stale_running_run: false
          }
        }

        ControlSnapshot.stub(
          :call,
          control
        ) do
          System::PipelineController.stub(
            :actor_behavior_decision,
            strict_behavior
          ) do
            decision =
              System::PipelineController.decision(
                :actor_behavior_heavy,

                current_snapshot:
                  base_snapshot
              )

            assert decision[:allowed]
            assert_equal :run, decision[:state]

            assert_equal(
              :actor_behavior_heavy_work_available,
              decision[:reason]
            )
          end
        end
      end

      test "active ActorLabels blocks Heavy" do
        control = {
          status: "active",
          auto_enabled: true,
          labels_enabled: true,
          cooldown_active: false,
          work_available: true
        }

        strict_behavior = {
          state: :idle,

          actor_behavior: {
            work_available: false,
            batch_running: false,
            stale_running_run: false
          }
        }

        snapshot =
          base_snapshot.deep_merge(
            actor_labels: {
              processing: true,
              strict_worker_busy: true
            }
          )

        ControlSnapshot.stub(
          :call,
          control
        ) do
          System::PipelineController.stub(
            :actor_behavior_decision,
            strict_behavior
          ) do
            decision =
              System::PipelineController.decision(
                :actor_behavior_heavy,

                current_snapshot:
                  snapshot
              )

            refute decision[:allowed]
            assert_equal :blocked, decision[:state]

            assert_includes(
              decision[:failed_constraints],
              :actor_labels_strict_active
            )
          end
        end
      end

      test "scheduler places Heavy before ActorLabels" do
        jobs =
          StrictPipeline::Scheduler::JOBS

        heavy_index =
          jobs.index do |job|
            job.name ==
              :actor_behavior_heavy
          end

        labels_index =
          jobs.index do |job|
            job.name ==
              :actor_labels
          end

        refute_nil heavy_index
        refute_nil labels_index

        assert_operator(
          heavy_index,
          :<,
          labels_index
        )

        heavy =
          jobs[
            heavy_index
          ]

        assert_equal(
          "actor_behavior_heavy",
          heavy.queue
        )

        assert_equal(
          "ActorBehaviors::HeavyBatchJob",
          heavy.klass
        )

        assert_equal(
          :active_job_keywords,
          heavy.kind
        )

        assert_equal(
          1,
          heavy.args.first[:limit]
        )
      end

      private

      def base_snapshot
        {
          bitcoin_core: {
            available: true,
            best_height: 956_951
          },

          layer1: {
            processed_height: 956_951,
            checkpoint_available: true,
            idle: true,
            processing: false,
            catching_up: false
          },

          cluster: {
            processed_height: 956_951,
            checkpoint_available: true,
            idle: true,
            processing: false,
            caught_up_to_layer1: true
          },

          actor_profile: {
            checkpoint_available: true,
            processing: false,
            strict_queue_size: 0,
            strict_worker_busy: false,
            pending_work: 0,
            caught_up_to_cluster: true
          },

          actor_labels: {
            processing: false,
            strict_queue_size: 0,
            strict_worker_busy: false,
            lock_present: false
          },

          strict_io: {
            owner: nil
          }
        }
      end

      def with_env(values)
        previous =
          values.to_h do |key, _value|
            [
              key,
              ENV.key?(key) ?
                ENV[key] :
                :__missing__
            ]
          end

        values.each do |key, value|
          if value.nil?
            ENV.delete(key)
          else
            ENV[key] =
              value
          end
        end

        yield
      ensure
        previous.each do |key, value|
          if value ==
             :__missing__
            ENV.delete(key)
          else
            ENV[key] =
              value
          end
        end
      end
    end
  end
end
