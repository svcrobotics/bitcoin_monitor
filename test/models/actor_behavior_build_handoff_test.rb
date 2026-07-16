# frozen_string_literal: true

require "test_helper"

class ActorBehaviorBuildHandoffTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "identity, transitions and JSON serialization are durable" do
    cluster = Cluster.create!(composition_version: 3)
    profile = ActorProfile.create!(
      cluster: cluster,
      cluster_composition_version: 3,
      last_computed_height: 900,
      certification_scope: "strict",
      certified_at: Time.current,
      dirty: false,
      traits: { "profile_version" => "strict_v3_core" },
      metadata: {
        "strict" => true,
        "address_spend_projection_hash" => "h-900"
      }
    )
    handoff = ActorBehaviorBuildHandoff.create!(
      cluster: cluster,
      actor_profile: profile,
      cluster_composition_version: 3,
      profile_version: "strict_v3_core",
      source_height: 900,
      source_hash: "h-900"
    )

    assert_equal "pending", handoff.status
    handoff.claim!(at: Time.current)
    assert_equal 1, handoff.attempts
    handoff.complete!(at: Time.current)
    assert_equal "completed", handoff.status
    assert JSON.generate(handoff.attributes)
    assert_raises(ActiveRecord::RecordInvalid) do
      handoff.update!(source_height: 901)
    end
  ensure
    ActorBehaviorBuildHandoff.delete_all
    ActorProfile.delete_all
    Cluster.delete_all
  end

  test "database rejects invalid provenance and duplicate identity" do
    cluster = Cluster.create!(composition_version: 1)
    profile = ActorProfile.create!(cluster: cluster)
    attributes = {
      cluster_id: cluster.id,
      actor_profile_id: profile.id,
      cluster_composition_version: 1,
      profile_version: "strict_v3_core",
      source_height: 10,
      source_hash: "hash",
      status: "pending",
      attempts: 0,
      created_at: Time.current,
      updated_at: Time.current
    }
    ActorBehaviorBuildHandoff.insert!(attributes)

    assert_raises(ActiveRecord::RecordNotUnique) do
      ApplicationRecord.transaction(requires_new: true) do
        ActorBehaviorBuildHandoff.insert!(attributes)
      end
    end
    assert_raises(ActiveRecord::StatementInvalid) do
      ApplicationRecord.transaction(requires_new: true) do
        ActorBehaviorBuildHandoff.insert!(attributes.merge(source_height: -1))
      end
    end
  ensure
    ActorBehaviorBuildHandoff.delete_all
    ActorProfile.delete_all
    Cluster.delete_all
  end

  test "concurrent registration creates one durable handoff" do
    cluster = Cluster.create!(composition_version: 2)
    profile = ActorProfile.create!(
      cluster: cluster,
      cluster_composition_version: 2,
      last_computed_height: 901,
      certification_scope: "strict",
      certified_at: Time.current,
      dirty: false,
      traits: { "profile_version" => "strict_v3_core" },
      metadata: {
        "strict" => true,
        "address_spend_projection_hash" => "h-901"
      }
    )
    arguments = {
      actor_profile: profile,
      composition_version: 2,
      profile_version: "strict_v3_core",
      source_height: 901,
      source_hash: "h-901"
    }

    results = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ActorBehaviors::HandoffRegistration.call(**arguments)
        end
      end
    end.map(&:value)

    assert_equal %w[already_registered created], results.map { |result| result[:status] }.sort
    assert_equal 1, ActorBehaviorBuildHandoff.where(cluster_id: cluster.id).count
  ensure
    ActorBehaviorBuildHandoff.delete_all
    ActorProfile.delete_all
    Cluster.delete_all
  end
end
