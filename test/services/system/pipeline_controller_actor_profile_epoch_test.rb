# frozen_string_literal: true

require "test_helper"

module System
  class PipelineControllerActorProfileEpochTest <
    ActiveSupport::TestCase

    test "inactive epoch exposes no checkpoint or backlog" do
      source = {
        certification: {
          epoch_active: false,
          certification_epoch_height: nil
        },

        progress: {
          pending_profiles: 500_000,
          pending_profiles_since_epoch: 0
        },

        sync: {
          profile_max_height: 957_000
        },

        automation: {
          queue_size: 0,
          busy_workers: 0,
          lock_ttl: 0
        }
      }

      snapshot =
        actor_profile_snapshot(
          source,
          cluster_processed: 957_300
        )

      assert_equal false, snapshot[:epoch_active]
      assert_nil snapshot[:certification_epoch_height]
      assert_equal 0, snapshot[:checkpoint_height]
      assert_equal false, snapshot[:checkpoint_available]
      assert_equal false, snapshot[:caught_up_to_cluster]
      assert_equal 0, snapshot[:pending_work]
    end

    test "active epoch exposes only epoch backlog" do
      source = {
        certification: {
          epoch_active: true,
          certification_epoch_height: 957_268
        },

        progress: {
          pending_profiles: 500_000,
          pending_profiles_since_epoch: 238
        },

        sync: {
          profile_max_height: 0
        },

        automation: {
          queue_size: 0,
          busy_workers: 0,
          lock_ttl: 0
        }
      }

      snapshot =
        actor_profile_snapshot(
          source,
          cluster_processed: 957_400
        )

      assert_equal true, snapshot[:epoch_active]

      assert_equal(
        957_268,
        snapshot[:certification_epoch_height]
      )

      assert_equal(
        957_268,
        snapshot[:checkpoint_height]
      )

      assert_equal true, snapshot[:checkpoint_available]
      assert_equal false, snapshot[:caught_up_to_cluster]
      assert_equal 238, snapshot[:pending_work]
    end

    test "active epoch is caught up when its backlog is empty" do
      source = {
        certification: {
          epoch_active: true,
          certification_epoch_height: 957_268
        },

        progress: {
          pending_profiles_since_epoch: 0
        },

        sync: {
          profile_max_height: 0
        },

        automation: {
          queue_size: 0,
          busy_workers: 0,
          lock_ttl: 0
        }
      }

      snapshot =
        actor_profile_snapshot(
          source,
          cluster_processed: 999_999
        )

      assert_equal true, snapshot[:checkpoint_available]
      assert_equal true, snapshot[:caught_up_to_cluster]
      assert_equal 0, snapshot[:pending_work]
    end

    test "active processing prevents caught up state" do
      source = {
        certification: {
          epoch_active: true,
          certification_epoch_height: 957_268
        },

        progress: {
          pending_profiles_since_epoch: 0
        },

        automation: {
          queue_size: 0,
          busy_workers: 1,
          lock_ttl: 30
        }
      }

      snapshot =
        actor_profile_snapshot(
          source,
          cluster_processed: 957_268
        )

      assert_equal true, snapshot[:processing]
      assert_equal false, snapshot[:caught_up_to_cluster]
    end

    private

    def actor_profile_snapshot(
      source,
      cluster_processed:
    )
      snapshot_class =
        ActorProfiles::
          OperationalSnapshot

      original_read =
        snapshot_class.method(
          :read
        )

      snapshot_class.define_singleton_method(
        :read
      ) do
        source
      end

      PipelineController.send(
        :actor_profile_snapshot,
        cluster_processed:
          cluster_processed
      )
    ensure
      if original_read
        snapshot_class.define_singleton_method(
          :read,
          original_read
        )
      end
    end
  end
end
