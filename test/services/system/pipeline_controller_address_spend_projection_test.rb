# frozen_string_literal: true

require "test_helper"

module System
  class PipelineControllerAddressSpendProjectionTest <
    ActiveSupport::TestCase

    test "registers projection between Cluster and ActorProfile" do
      registry =
        PipelineController::
          PIPELINE_REGISTRY

      projection =
        registry.fetch(
          :address_spend_projection
        )

      profile =
        registry.fetch(
          :actor_profile
        )

      assert_equal 2,
                   registry.dig(
                     :cluster,
                     :priority
                   )

      assert_equal 3,
                   projection[:priority]

      assert_equal(
        [:cluster],
        projection[:depends_on]
      )

      assert_equal 4,
                   profile[:priority]

      assert_equal(
        [:address_spend_projection],
        profile[:depends_on]
      )
    end

    test "projection has work when a certified height remains" do
      snapshot =
        stable_snapshot.deep_merge(
          address_spend_projection: {
            next_record_height:
              956_251,
            work_available: true,
            caught_up_to_cluster:
              false
          }
        )

      decision =
        PipelineController.decision(
          :address_spend_projection,
          current_snapshot:
            snapshot
        )

      assert decision[:allowed]

      assert(
        PipelineController
          .work_available?(
            decision
          )
      )
    end

    test "ActorProfile waits while projection is behind" do
      snapshot =
        stable_snapshot.deep_merge(
          address_spend_projection: {
            checkpoint_height:
              956_249,
            caught_up_to_cluster:
              false,
            lag: 1,
            next_record_height:
              956_250,
            work_available:
              true
          }
        )

      decision =
        PipelineController.decision(
          :actor_profile,
          current_snapshot:
            snapshot
        )

      refute decision[:allowed]

      assert_equal(
        :address_spend_projection_priority,
        decision[:reason]
      )

      assert_includes(
        decision[:failed_constraints],
        :address_spend_projection_ready
      )
    end

    test "ActorProfile is allowed after projection reaches Cluster" do
      decision =
        PipelineController.decision(
          :actor_profile,
          current_snapshot:
            stable_snapshot
        )

      assert decision[:allowed]
      assert_empty decision[:failed_constraints]
    end

    test "ActorProfile is allowed at certified Cluster checkpoint when Layer1 is slightly ahead" do
      snapshot =
        stable_snapshot.deep_merge(
          bitcoin_core: {
            best_height: 957_820
          },

          layer1: {
            processed_height: 957_820,
            lag: 0
          },

          cluster: {
            processed_height: 957_815,
            lag: 5,
            global_lag: 5,
            caught_up_to_layer1: false
          },

          address_spend_projection: {
            checkpoint_height: 957_815,
            caught_up_to_cluster: true,
            lag: 0,
            next_record_height: nil,
            work_available: false
          },

          actor_profile: {
            pending_work: 81_127,
            processing: false,
            caught_up_to_cluster: false,
            strict_queue_size: 0,
            strict_worker_busy: false
          }
        )

      decision =
        PipelineController.decision(
          :actor_profile,
          current_snapshot:
            snapshot
        )

      assert decision[:allowed]
      assert_empty decision[:failed_constraints]
      assert(
        PipelineController.work_available?(
          decision
        )
      )
    end

    test "ActorProfile has no work when backlog is empty" do
      decision =
        PipelineController.decision(
          :actor_profile,
          current_snapshot:
            stable_snapshot.deep_merge(
              actor_profile: {
                pending_work: 0,
                caught_up_to_cluster: true
              }
            )
        )

      assert decision[:allowed]
      refute(
        PipelineController.work_available?(
          decision
        )
      )
    end

    private

    def stable_snapshot
      {
        bitcoin_core: {
          available: true,
          best_height: 956_250
        },

        layer1: {
          processed_height: 956_250,
          checkpoint_available: true,
          lag: 0,
          processing: false,
          buffers_empty: true,
          strict_queue_size: 0,
          strict_worker_busy: false,
          catching_up: false
        },

        cluster: {
          processed_height: 956_250,
          checkpoint_available: true,
          lag: 0,
          global_lag: 0,
          processing: false,
          strict_queue_size: 0,
          strict_worker_busy: false,
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
          failed: false
        },

        actor_profile: {
          checkpoint_available: true,
          pending_work: 10,
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
  end
end
