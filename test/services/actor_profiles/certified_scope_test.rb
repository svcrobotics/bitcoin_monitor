# frozen_string_literal: true

require "test_helper"

module ActorProfiles
  class CertifiedScopeTest <
    ActiveSupport::TestCase

    def setup
      @epoch_height = 100

      @epoch =
        ActorProfileCertificationEpoch.create!(
          profile_version:
            StrictBuildFromCluster::
              PROFILE_VERSION,
          start_height:
            @epoch_height,
          activated_at:
            Time.current,
          source:
            ActorProfileCertificationEpoch::
              SOURCE_CLUSTER_STRICT_CHECKPOINT,
          metadata: {}
        )
    end

    test "returns no certified profiles without active epoch" do
      profile =
        create_profile

      ActorProfileCertificationEpoch.delete_all

      refute_includes(
        CertifiedScope.call,
        profile
      )
    end

    test "includes profile certified in active epoch" do
      profile =
        create_profile

      assert_includes(
        CertifiedScope.call,
        profile
      )
    end

    test "rejects profile without epoch stamp" do
      profile =
        create_profile(
          certification_epoch_height: nil,
          certification_scope: nil,
          certified_at: nil
        )

      refute_includes(
        CertifiedScope.call,
        profile
      )
    end

    test "rejects profile from another epoch" do
      profile =
        create_profile(
          certification_epoch_height:
            @epoch_height - 1
        )

      refute_includes(
        CertifiedScope.call,
        profile
      )
    end

    private

    def create_profile(
      certification_epoch_height:
        @epoch_height,
      certification_scope:
        ActorProfile::
          CERTIFICATION_SCOPE_ACTIVITY_SINCE_EPOCH,
      certified_at:
        Time.current
    )
      cluster =
        Cluster.create!(
          address_count: 1,
          first_seen_height: 90,
          last_seen_height:
            @epoch_height,
          composition_version: 1
        )

      Address.create!(
        address:
          "certified-#{SecureRandom.hex(8)}",
        cluster:
          cluster
      )

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
          @epoch_height,

        cluster_composition_version:
          1,

        certification_epoch_height:
          certification_epoch_height,

        certification_scope:
          certification_scope,

        certified_at:
          certified_at,

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
  end
end
