# frozen_string_literal: true

require "test_helper"

class ClusterTransactionProjectionGenerationTest < ActiveSupport::TestCase
  test "contracts states checkpoints and certified uniqueness" do
    generation = build_generation(status: "certified", certified_at: Time.current)
    assert generation.valid?
    assert generation.certified?
    assert_equal ClusterTransactionProjectionGeneration::STATUSES,
      %w[pending building certified failed stale replaced]

    assert_not build_generation(status: "certified", certified_at: nil).valid?
    assert_not build_generation(base_checkpoint_height: 11, checkpoint_height: 10).valid?

    generation.save!
    assert_raises(ActiveRecord::RecordNotUnique) do
      ClusterTransactionProjectionGeneration.transaction(requires_new: true) do
        build_generation(cluster_id: generation.cluster_id, composition_version: 2,
          status: "certified", certified_at: Time.current).save!
      end
    end
  end

  test "deletes dependent facts with a generation" do
    generation = build_generation
    generation.save!
    generation.facts.create!(txid: "a" * 32, received_height: 10)

    assert_difference("ClusterTransactionFact.count", -1) { generation.destroy! }
  end

  private

  def build_generation(overrides = {})
    ClusterTransactionProjectionGeneration.new({
      cluster_id: 9_000_001,
      composition_version: 1,
      base_checkpoint_height: 10,
      base_checkpoint_hash: "base",
      checkpoint_height: 10,
      checkpoint_hash: "checkpoint",
      source: "test",
      status: "building"
    }.merge(overrides))
  end
end
