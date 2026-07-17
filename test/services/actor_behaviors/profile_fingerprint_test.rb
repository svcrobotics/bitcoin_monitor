# frozen_string_literal: true

require "test_helper"

module ActorBehaviors
  class ProfileFingerprintTest < ActiveSupport::TestCase
    test "is stable with the same values" do
      profile =
        create_profile

      first =
        ActorBehaviors::ProfileFingerprint.call(profile)

      second =
        ActorBehaviors::ProfileFingerprint.call(profile.reload)

      assert_equal first, second
    end

    test "changes when a used fact changes" do
      profile =
        create_profile

      first =
        ActorBehaviors::ProfileFingerprint.call(profile)

      profile.update!(
        balance_btc: "2.0"
      )

      second =
        ActorBehaviors::ProfileFingerprint.call(profile.reload)

      refute_equal first, second
    end

    test "uses a canonical fixed key order" do
      profile =
        create_profile

      payload =
        ActorBehaviors::ProfileFingerprint.payload(profile)

      assert_equal(
        ActorBehaviors::ProfileFingerprint::KEYS.map(&:to_s),
        payload.map(&:first)
      )
    end

    private

    def create_profile
      cluster =
        Cluster.create!(
          address_count: 1,
          first_seen_height: 90,
          last_seen_height: 100,
          composition_version: 1
        )

      Address.create!(
        address: "behavior-fingerprint-#{SecureRandom.hex(8)}",
        cluster: cluster
      )

      ActorProfile.create!(
        cluster: cluster,
        balance_btc: "1.0",
        total_received_btc: "1.0",
        total_sent_btc: "0.0",
        net_btc: "1.0",
        tx_count: 1,
        inflow_count: 1,
        outflow_count: 0,
        first_seen_at: Time.utc(2026, 1, 1, 0, 0, 0),
        last_seen_at: Time.utc(2026, 1, 2, 0, 0, 0),
        dirty: false,
        last_computed_height: 100,
        cluster_composition_version: 1,
        traits: {
          "profile_version" =>
            ActorProfiles::StrictBuildFromCluster::PROFILE_VERSION,
          "address_count" => 1,
          "first_seen_height" => 90,
          "last_seen_height" => 100
        },
        metadata: {
          "strict" => true
        }
      )
    end
  end
end
