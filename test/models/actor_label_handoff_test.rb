# frozen_string_literal: true

require "test_helper"

class ActorLabelHandoffTest < ActiveSupport::TestCase
  test "identity is durable and unique" do
    cluster = Cluster.create!(composition_version: 1)
    profile = ActorProfile.create!(cluster: cluster)
    snapshot = ActorBehaviorSnapshot.create!(cluster: cluster, actor_profile: profile,
      profile_version: "strict_v3_core", profile_height: 10,
      cluster_composition_version: 1, profile_fingerprint: "fp",
      behavior_version: "strict_v2", status: "certified", source_hash: "hash",
      certification_scope: "strict", certified_at: Time.current,
      computed_at: Time.current)
    first = ActorLabels::HandoffRegistration.call(snapshot: snapshot)
    second = ActorLabels::HandoffRegistration.call(snapshot: snapshot)

    assert_equal "created", first[:status]
    assert_equal "already_registered", second[:status]
    assert_equal first[:handoff_id], second[:handoff_id]
    assert JSON.generate(first)
    assert_equal ActorLabels::StrictRuleSetV2::ACTIVE_RULES,
      %w[whale_like whale_candidate]
    assert_equal ActorLabels::StrictRuleSetV2::DEFERRED_RULES,
      %w[accumulator_like distributor_like etf_candidate]
  end
end
