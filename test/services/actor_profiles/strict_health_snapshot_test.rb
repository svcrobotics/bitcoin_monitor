# frozen_string_literal: true

require "test_helper"

module ActorProfiles
  class StrictHealthSnapshotTest <
    ActiveSupport::TestCase

    self.use_transactional_tests = false

    def setup
      cleanup_records
      @height = 9_970_000
    end

    def teardown
      cleanup_records
    end

    test "is inactive without certification epoch" do
      snapshot =
        StrictHealthSnapshot.call

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

      assert_includes(
        snapshot[:issues],
        "certification_epoch_inactive"
      )
    end

    test "counts only clusters active since epoch" do
      create_tips
      create_epoch

      create_cluster(
        last_seen_height:
          @height - 1
      )

      certified_cluster =
        create_cluster(
          last_seen_height:
            @height
        )

      create_cluster(
        last_seen_height:
          @height
      )

      create_certified_profile(
        certified_cluster
      )

      snapshot =
        StrictHealthSnapshot.call

      assert_equal(
        true,
        snapshot.dig(
          :certification,
          :epoch_active
        )
      )

      assert_equal(
        @height,
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
          :missing_profiles
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

      assert_equal(
        0,
        snapshot.dig(
          :integrity,
          :profile_partition_delta
        )
      )
    end

    private

    def create_tips
      BlockBufferModel.create!(
        height:
          @height,

        block_hash:
          unique_hash("layer1"),

        status:
          "processed",

        processed_at:
          Time.current
      )

      ClusterProcessedBlock.create!(
        height:
          @height,

        block_hash:
          unique_hash("cluster"),

        status:
          "processed",

        processed_at:
          Time.current
      )
    end

    def create_epoch
      ActorProfileCertificationEpoch.create!(
        profile_version:
          StrictBuildFromCluster::
            PROFILE_VERSION,

        start_height:
          @height,

        activated_at:
          Time.current,

        source:
          ActorProfileCertificationEpoch::
            SOURCE_CLUSTER_STRICT_CHECKPOINT,

        metadata: {}
      )
    end

    def create_cluster(last_seen_height:)
      cluster =
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

      2.times do |index|
        Address.create!(
          address:
            "snapshot-#{index}-#{SecureRandom.hex(8)}",

          cluster:
            cluster
        )
      end

      cluster
    end

    def create_certified_profile(cluster)
      ActorProfile.create!(
        cluster:
          cluster,

        balance_btc:
          "1.0",

        total_received_btc:
          "1.0",

        total_sent_btc:
          "0.0",

        net_btc:
          "1.0",

        tx_count:
          1,

        inflow_count:
          1,

        outflow_count:
          0,

        dirty:
          false,

        last_computed_height:
          @height,

        cluster_composition_version:
          cluster.composition_version,

        certification_epoch_height:
          @height,

        certification_scope:
          ActorProfile::
            CERTIFICATION_SCOPE_ACTIVITY_SINCE_EPOCH,

        certified_at:
          Time.current,

        traits: {
          "profile_version" =>
            StrictBuildFromCluster::
              PROFILE_VERSION
        },

        metadata: {
          "strict" => true
        }
      )
    end

    def unique_hash(prefix)
      Digest::SHA256.hexdigest(
        "#{prefix}-#{SecureRandom.hex(16)}"
      )
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
