# frozen_string_literal: true

require "test_helper"

class ClusterActorProfileHandoffTest < ActiveSupport::TestCase
  setup do
    ActorBehaviorBuildHandoff.delete_all
    ClusterActorProfileHandoff.delete_all
    Cluster.delete_all
    @cluster = Cluster.create!
  end

  test "validates certification identity and dimensions" do
    assert build_handoff.valid?
    assert_not build_handoff(cluster_height: -1).valid?
    assert_not build_handoff(block_hash: nil).valid?
    assert_not build_handoff(composition_version: 0).valid?
    assert_not build_handoff(attempts: -1).valid?
    assert_not build_handoff(status: "unknown").valid?
  end

  test "enforces one row per certification cluster and version" do
    create_handoff

    duplicate = build_handoff
    assert_not duplicate.valid?
    assert duplicate.errors.added?(:cluster_id, :taken, value: @cluster.id)
    assert build_handoff(block_hash: "another-hash").valid?
    assert build_handoff(composition_version: 2).valid?
  end

  test "allows only pending or failed through processing to a terminal state" do
    handoff = create_handoff
    handoff.claim!(at: Time.current)
    assert_equal "processing", handoff.status
    assert_equal 1, handoff.attempts
    assert handoff.claimed_at.present?

    handoff.fail!(error_class: "ActorProfiles::DeferredSnapshotError")
    assert_equal "failed", handoff.status
    assert_equal "ActorProfiles::DeferredSnapshotError", handoff.last_error_class

    handoff.claim!(at: Time.current)
    handoff.complete!(at: Time.current)
    assert_equal "completed", handoff.status
    assert handoff.completed_at.present?
    assert_raises(ActiveRecord::RecordInvalid) { handoff.update!(status: "processing") }
  end

  test "rejects direct terminal transitions and immutable identity changes" do
    handoff = create_handoff

    assert_raises(ActiveRecord::RecordInvalid) do
      handoff.update!(status: "completed", completed_at: Time.current)
    end
    assert_raises(ActiveRecord::RecordInvalid) do
      handoff.update!(composition_version: 2)
    end
    assert_equal 1, handoff.reload.composition_version
  end

  test "claimable scope is deterministic and excludes processing and completed" do
    pending = create_handoff(cluster_height: 3)
    failed = create_handoff(cluster_height: 1, block_hash: "failed")
    failed.claim!
    failed.fail!(error_class: "RuntimeError")
    processing = create_handoff(cluster_height: 2, block_hash: "processing")
    processing.claim!
    completed = create_handoff(cluster_height: 4, block_hash: "completed")
    completed.claim!
    completed.complete!

    assert_equal [failed.id, pending.id],
      ClusterActorProfileHandoff.claimable.order(:cluster_height, :cluster_id, :id).pluck(:id)
  end

  test "is JSON serializable without runtime dependencies" do
    handoff = create_handoff
    payload = handoff.attributes.slice(
      "cluster_height", "block_hash", "cluster_id", "composition_version", "status", "attempts"
    )
    source = File.read(Rails.root.join("app/models/cluster_actor_profile_handoff.rb"))

    assert JSON.generate(payload)
    assert_no_match(/Redis|Sidekiq/, source)
  end

  private

  def build_handoff(**attributes)
    ClusterActorProfileHandoff.new({
      cluster_height: 910_000,
      block_hash: "certified-hash",
      cluster: @cluster,
      composition_version: 1,
      status: "pending",
      attempts: 0
    }.merge(attributes))
  end

  def create_handoff(**attributes)
    build_handoff(**attributes).tap(&:save!)
  end
end
