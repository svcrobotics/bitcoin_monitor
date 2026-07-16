# frozen_string_literal: true

require "test_helper"

class ClusterTransactionFactTest < ActiveSupport::TestCase
  test "belongs to a generation and requires a 32 byte txid with activity" do
    generation = ClusterTransactionProjectionGeneration.create!(
      cluster_id: 9_000_002, composition_version: 1,
      base_checkpoint_height: 10, base_checkpoint_hash: "base",
      checkpoint_height: 10, checkpoint_hash: "checkpoint",
      source: "test", status: "building"
    )

    fact = generation.facts.build(txid: "a" * 32, received_height: 10)
    assert fact.valid?
    assert_equal generation, fact.projection_generation

    assert_not generation.facts.build(txid: "a" * 31, received_height: 10).valid?
    assert_not generation.facts.build(txid: "a" * 32).valid?
    assert_not generation.facts.build(txid: "a" * 32, spent_height: -1).valid?
  end
end
