# frozen_string_literal: true

require "test_helper"

module ActorProfiles
  class CertificationEpochAutoActivatorTest <
    ActiveSupport::TestCase

    def setup
      ActorProfileCertificationEpoch.delete_all
    end

    def teardown
      ActorProfileCertificationEpoch.delete_all
    end

    test "waits when the epoch state is absent" do
      result =
        CertificationEpochAutoActivator.call(
          snapshot: {
            cluster: {
              processed_height: 1_000,
              checkpoint_available: true
            }
          }
        )

      assert_equal "waiting", result[:status]

      assert_equal(
        "actor_profile_epoch_state_unknown",
        result[:reason]
      )

      assert_equal(
        0,
        ActorProfileCertificationEpoch.count
      )
    end

    test "waits while projection is behind cluster" do
      result =
        CertificationEpochAutoActivator.call(
          snapshot:
            aligned_snapshot.deep_merge(
              address_spend_projection: {
                checkpoint_height: 999,
                caught_up_to_cluster: false
              }
            )
        )

      assert_equal "waiting", result[:status]

      assert_equal(
        "address_spend_projection_not_caught_up",
        result[:reason]
      )

      assert_equal(
        0,
        ActorProfileCertificationEpoch.count
      )
    end

    test "creates epoch ten blocks before cluster checkpoint" do
      operational = {
        progress: {
          pending_profiles_since_epoch: 7
        }
      }

      snapshot_class =
        ActorProfiles::
          OperationalSnapshot

      original_refresh =
        snapshot_class.method(
          :refresh!
        )

      snapshot_class.define_singleton_method(
        :refresh!
      ) do
        operational
      end

      result =
        CertificationEpochAutoActivator.call(
          snapshot:
            aligned_snapshot
        )
    ensure
      if original_refresh
        snapshot_class.define_singleton_method(
          :refresh!,
          original_refresh
        )
      end

      epoch =
        ActorProfiles::
          CertificationEpoch.current

      assert_equal "activated", result[:status]
      assert_equal 990, result[:start_height]
      assert_equal 10, result[:lookback_blocks]
      assert_equal 7, result[:pending_profiles_since_epoch]

      assert_not_nil epoch
      assert_equal 990, epoch.start_height

      metadata =
        epoch.reload.metadata

      assert_equal(
        "scheduler_auto_cluster_lookback",
        metadata["activation_mode"]
      )

      assert_equal(
        10,
        metadata["lookback_blocks"]
      )

      assert_equal(
        1_000,
        metadata["cluster_checkpoint"]
      )

      assert_equal(
        1_000,
        metadata["projection_checkpoint"]
      )
    end

    test "is idempotent after activation" do
      epoch =
        ActorProfileCertificationEpoch.create!(
          profile_version:
            StrictBuildFromCluster::
              PROFILE_VERSION,

          start_height:
            990,

          activated_at:
            Time.current,

          source:
            ActorProfileCertificationEpoch::
              SOURCE_CLUSTER_STRICT_CHECKPOINT,

          metadata: {
            lookback_blocks: 10
          }
        )

      result =
        CertificationEpochAutoActivator.call(
          snapshot:
            aligned_snapshot
        )

      assert_equal "existing", result[:status]
      assert_equal epoch.id, result[:epoch_id]
      assert_equal 990, result[:start_height]

      assert_equal(
        1,
        ActorProfileCertificationEpoch.count
      )
    end

    private

    def aligned_snapshot
      {
        layer1: {
          processed_height: 1_005
        },

        cluster: {
          processed_height: 1_000,
          checkpoint_available: true
        },

        address_spend_projection: {
          available: true,
          checkpoint_available: true,
          checkpoint_height: 1_000,
          caught_up_to_cluster: true
        },

        actor_profile: {
          epoch_active: false
        }
      }
    end
  end
end
