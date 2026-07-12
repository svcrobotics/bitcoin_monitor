# frozen_string_literal: true

require "test_helper"

module ActorProfiles
  class OperationalSnapshotTest <
    ActiveSupport::TestCase

    self.use_transactional_tests = false

    def setup
      cleanup_records
      clear_cache
    end

    def teardown
      clear_cache
      cleanup_records
    end

    test "reports inactive epoch without historical backlog" do
      snapshot =
        OperationalSnapshot.refresh!

      assert_equal(
        "inactive",
        snapshot[:status]
      )

      assert_equal(
        false,
        snapshot.dig(
          :certification,
          :epoch_active
        )
      )

      assert_equal(
        0,
        snapshot.dig(
          :progress,
          :pending_profiles
        )
      )

      assert_equal(
        0,
        snapshot.dig(
          :progress,
          :pending_profiles_since_epoch
        )
      )

      assert_equal(
        "inactive",
        snapshot.dig(
          :activity,
          :pipeline_state
        )
      )

      assert_equal(
        "certification_epoch_inactive",
        snapshot.dig(
          :activity,
          :wait_reason
        )
      )
    end

    test "refresh from batch counts only active epoch scope" do
      epoch =
        ActorProfileCertificationEpoch.create!(
          profile_version:
            StrictBuildFromCluster::
              PROFILE_VERSION,

          start_height:
            100,

          activated_at:
            Time.current,

          source:
            ActorProfileCertificationEpoch::
              SOURCE_CLUSTER_STRICT_CHECKPOINT,

          metadata: {}
        )

      create_cluster(
        last_seen_height: 99
      )

      create_cluster(
        last_seen_height: 100
      )

      create_cluster(
        last_seen_height: 101
      )

      snapshot =
        OperationalSnapshot.refresh_from_batch(
          status:
            "completed",

          actor_profiles_count:
            1,

          missing_profiles_count:
            1,

          stale_profiles_count:
            0,

          layer1_tip:
            101,

          cluster_tip:
            101,

          selected:
            1,

          built:
            1,

          deferred:
            0,

          failed:
            0,

          duration_ms:
            10,

          avg_runtime_ms:
            10,

          selection_ms:
            1,

          build_loop_ms:
            8,

          counts_ms:
            1,

          successful_runtime_ms:
            8,

          deferred_or_overhead_runtime_ms:
            0,

          unattributed_runtime_ms:
            0
        )

      assert_equal(
        true,
        snapshot.dig(
          :certification,
          :epoch_active
        )
      )

      assert_equal(
        epoch.start_height,
        snapshot.dig(
          :certification,
          :certification_epoch_height
        )
      )

      assert_equal(
        2,
        snapshot.dig(
          :progress,
          :active_clusters_since_epoch
        )
      )

      assert_equal(
        1,
        snapshot.dig(
          :progress,
          :historical_clusters_outside_epoch
        )
      )

      assert_equal(
        1,
        snapshot.dig(
          :progress,
          :certified_profiles_since_epoch
        )
      )

      assert_equal(
        1,
        snapshot.dig(
          :progress,
          :pending_profiles_since_epoch
        )
      )

      assert_equal(
        50.0,
        snapshot.dig(
          :progress,
          :completion_pct
        )
      )
    end

    private

    def create_cluster(last_seen_height:)
      Cluster.create!(
        address_count:
          2,

        first_seen_height:
          last_seen_height - 10,

        last_seen_height:
          last_seen_height,

        composition_version:
          1
      )
    end

    def clear_cache
      Sidekiq.redis do |redis|
        redis.del(
          OperationalSnapshot::CACHE_KEY,
          OperationalSnapshot::RECENT_BATCHES_KEY
        )
      end
    end

    def cleanup_records
      ActorLabel.delete_all
      ActorProfile.delete_all
      Address.delete_all
      ActorProfileCertificationEpoch.delete_all
      ClusterProcessedBlock.delete_all
      BlockBufferModel.delete_all
      Cluster.delete_all
    end
  end
end
