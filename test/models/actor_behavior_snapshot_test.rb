# frozen_string_literal: true

require "test_helper"

class ActorBehaviorSnapshotTest < ActiveSupport::TestCase
  test "requires certified snapshot fields" do
    snapshot =
      ActorBehaviorSnapshot.new

    assert_not snapshot.valid?
    assert snapshot.errors.added?(:cluster, :blank)
    assert snapshot.errors.added?(:actor_profile, :blank)
    assert snapshot.errors.added?(:profile_version, :blank)
    assert snapshot.errors.added?(:profile_height, :blank)
    assert snapshot.errors.added?(:cluster_composition_version, :blank)
    assert snapshot.errors.added?(:profile_fingerprint, :blank)
    assert snapshot.errors.added?(:behavior_version, :blank)
    assert snapshot.errors.added?(:status, :blank)
    assert snapshot.errors.added?(:computed_at, :blank)
  end

  test "rejects unknown status" do
    profile =
      create_profile

    snapshot =
      ActorBehaviorSnapshot.new(
        cluster: profile.cluster,
        actor_profile: profile,
        profile_version: "strict_v1",
        profile_height: 100,
        cluster_composition_version: 1,
        profile_fingerprint: "abc",
        behavior_version: "strict_v1",
        status: "unknown",
        computed_at: Time.current
      )

    assert_not snapshot.valid?
    assert snapshot.errors.added?(:status, :inclusion, value: "unknown")
  end

  private

  def create_profile
    cluster =
      Cluster.create!(
        address_count: 1,
        last_seen_height: 100,
        composition_version: 1
      )

    Address.create!(
      address: "behavior-model-#{SecureRandom.hex(8)}",
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
      dirty: false,
      last_computed_height: 100,
      cluster_composition_version: 1,
      traits: {
        "profile_version" =>
          ActorProfiles::StrictBuildFromCluster::PROFILE_VERSION,
        "address_count" => 1
      },
      metadata: {
        "strict" => true
      }
    )
  end
end
