# frozen_string_literal: true

require "test_helper"

module ActorBehaviors
  class CertifiedScopeTest < ActiveSupport::TestCase
    test "accepts perfectly coherent snapshot" do
      profile =
        create_certified_profile

      snapshot =
        ActorBehaviors::StrictBuildFromProfile
          .call(actor_profile: profile)
          .fetch(:snapshot)

      assert_includes ActorBehaviors::CertifiedScope.call, snapshot
    end

    test "rejects obsolete snapshot without writing status" do
      profile =
        create_certified_profile(
          balance_btc: "1500.0"
        )

      snapshot =
        ActorBehaviors::StrictBuildFromProfile
          .call(actor_profile: profile)
          .fetch(:snapshot)

      original_status =
        snapshot.status

      profile.update!(
        balance_btc: "12000.0"
      )

      refute_includes ActorBehaviors::CertifiedScope.call, snapshot
      assert_equal original_status, snapshot.reload.status
      assert_equal 85, snapshot.scores["whale_score"]
    end

    test "rejects snapshot with mismatched behavior version" do
      profile =
        create_certified_profile

      snapshot =
        ActorBehaviors::StrictBuildFromProfile
          .call(actor_profile: profile)
          .fetch(:snapshot)

      snapshot.update!(
        behavior_version: "legacy"
      )

      refute_includes ActorBehaviors::CertifiedScope.call, snapshot
    end

    test "rejects snapshot with mismatched strict source hash" do
      profile =
        create_certified_profile

      snapshot =
        ActorBehaviors::StrictBuildFromProfile
          .call(actor_profile: profile)
          .fetch(:snapshot)

      snapshot.update!(
        source_hash: "different-profile-fingerprint"
      )

      refute_includes ActorBehaviors::CertifiedScope.call, snapshot
    end

    private

    def create_certified_profile(
      balance_btc: "1500.0"
    )
      epoch =
        ActorProfileCertificationEpoch.find_or_create_by!(
          profile_version:
            ActorProfiles::StrictBuildFromCluster::PROFILE_VERSION
        ) do |record|
          record.start_height = 90
          record.activated_at = Time.current
          record.source =
            ActorProfileCertificationEpoch::SOURCE_CLUSTER_STRICT_CHECKPOINT
          record.metadata = {}
        end

      cluster =
        Cluster.create!(
          address_count: 10,
          first_seen_height: 90,
          last_seen_height: 100,
          composition_version: 1
        )

      10.times do |index|
        Address.create!(
          address: "behavior-scope-#{index}-#{SecureRandom.hex(8)}",
          cluster: cluster
        )
      end

      ActorProfile.create!(
        cluster: cluster,
        balance_btc: balance_btc,
        total_received_btc: balance_btc,
        total_sent_btc: "0.0",
        net_btc: balance_btc,
        tx_count: 250,
        inflow_count: 250,
        outflow_count: 0,
        whale_score: 85,
        exchange_score: 20,
        service_score: 20,
        dirty: false,
        last_computed_height: 100,
        cluster_composition_version: 1,
        certification_epoch_height: epoch.start_height,
        certification_scope:
          ActorProfile::CERTIFICATION_SCOPE_ACTIVITY_SINCE_EPOCH,
        certified_at: Time.current,
        traits: {
          "profile_version" =>
            ActorProfiles::StrictBuildFromCluster::PROFILE_VERSION,
          "address_count" => 10,
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
