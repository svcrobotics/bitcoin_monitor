# frozen_string_literal: true

require "test_helper"

module ClusterTransactionProjection
  class LifecycleTest < ActiveSupport::TestCase
    def setup
      @height = 10

      @block_hash =
        unique_hash("cluster-tx-projection")
    end

    test "certifies a generation atomically with exact counters" do
      cluster =
        Cluster.create!(composition_version: 3)

      create_cluster_checkpoint(@height, @block_hash)

      generation =
        GenerationBuilder.call(
          cluster_id: cluster.id,
          composition_version: 3,
          checkpoint_height: @height,
          checkpoint_hash: @block_hash,
          facts: [
            fact("a", received_height: @height - 3),
            fact("b", spent_height: @height - 2),
            fact(
              "c",
              received_height: @height - 1,
              spent_height: @height
            ),
            fact("future", received_height: @height + 1)
          ]
        )

      result =
        Certifier.call(generation)

      assert_equal true, result.ok

      generation.reload
      assert_equal "certified", generation.status
      assert_equal 2, generation.inflow_count
      assert_equal 2, generation.outflow_count
      assert_equal 3, generation.tx_count
      assert_equal 4, generation.facts_count
      assert generation.certified_at.present?

      audit =
        CounterAudit.call(generation)

      assert_equal true, audit.ok
    end

    test "refuses certification when composition changed" do
      cluster =
        Cluster.create!(composition_version: 1)

      create_cluster_checkpoint(@height, @block_hash)

      generation =
        GenerationBuilder.call(
          cluster_id: cluster.id,
          composition_version: 1,
          checkpoint_height: @height,
          checkpoint_hash: @block_hash,
          facts: [
            fact("a", received_height: @height)
          ]
        )

      cluster.update!(composition_version: 2)

      result =
        Certifier.call(generation)

      assert_equal false, result.ok
      assert_equal :composition_mismatch, result.reason
      assert_equal "stale", generation.reload.status
      assert_nil generation.certified_at
    end

    test "refuses certification without exact cluster checkpoint" do
      cluster =
        Cluster.create!(composition_version: 1)

      generation =
        GenerationBuilder.call(
          cluster_id: cluster.id,
          composition_version: 1,
          checkpoint_height: @height,
          checkpoint_hash: @block_hash,
          facts: [
            fact("a", received_height: @height)
          ]
        )

      result =
        Certifier.call(generation)

      assert_equal false, result.ok
      assert_equal :checkpoint_missing, result.reason
      assert_equal "failed", generation.reload.status
    end

    test "readiness reports ready and non ready states" do
      cluster =
        Cluster.create!(composition_version: 1)

      assert_equal(
        :missing,
        Readiness.call(
          cluster_id: cluster.id,
          cluster_checkpoint: @height,
          composition_version: 1
        ).status
      )

      create_cluster_checkpoint(@height, @block_hash)

      generation =
        GenerationBuilder.call(
          cluster_id: cluster.id,
          composition_version: 1,
          checkpoint_height: @height,
          checkpoint_hash: @block_hash,
          facts: [
            fact("a", received_height: @height)
          ]
        )

      assert_equal(
        :building,
        Readiness.call(
          cluster_id: cluster.id,
          cluster_checkpoint: @height,
          composition_version: 1
        ).status
      )

      Certifier.call(generation)

      create_projection_chain(@height, @block_hash)

      ready =
        Readiness.call(
          cluster_id: cluster.id,
          cluster_checkpoint: @height,
          composition_version: 1
        )

      assert_equal true, ready.ready?
      assert_equal(
        {
          inflow_count: 1,
          outflow_count: 0,
          tx_count: 1
        },
        ready.counts
      )

      assert_equal(
        :behind_checkpoint,
        Readiness.call(
          cluster_id: cluster.id,
          cluster_checkpoint: @height + 1,
          composition_version: 1
        ).status
      )

      assert_equal(
        :composition_mismatch,
        Readiness.call(
          cluster_id: cluster.id,
          cluster_checkpoint: @height,
          composition_version: 2
        ).status
      )
    end

    test "readiness reports strengthened non ready states" do
      cluster =
        Cluster.create!(composition_version: 1)

      create_cluster_checkpoint(@height, @block_hash)

      generation =
        GenerationBuilder.call(
          cluster_id: cluster.id,
          composition_version: 1,
          checkpoint_height: @height,
          checkpoint_hash: @block_hash,
          facts: [
            fact("a", received_height: @height)
          ]
        )

      Certifier.call(generation)

      assert_equal(
        :invalid_composition_revision,
        Readiness.call(
          cluster_id: cluster.id,
          cluster_checkpoint: @height,
          composition_version: 0
        ).status
      )

      assert_equal(
        :ready,
        Readiness.call(
          cluster_id: cluster.id,
          cluster_checkpoint: @height,
          composition_version: 1
        ).status
      )

      ClusterProcessedBlock
        .find_by!(height: @height)
        .update!(block_hash: unique_hash("changed-checkpoint"))

      assert_equal(
        :hash_mismatch,
        Readiness.call(
          cluster_id: cluster.id,
          cluster_checkpoint: @height,
          composition_version: 1
        ).status
      )

      ClusterProcessedBlock
        .find_by!(height: @height)
        .update!(block_hash: @block_hash)

      generation.update!(
        base_checkpoint_height: @height - 2,
        base_checkpoint_hash: unique_hash("base")
      )

      ClusterTransactionProjectionBlock.create!(
        block_height: @height,
        block_hash: @block_hash,
        status: "projected",
        completed_at: Time.current
      )

      assert_equal(
        :projection_gap,
        Readiness.call(
          cluster_id: cluster.id,
          cluster_checkpoint: @height,
          composition_version: 1
        ).status
      )
    end

    test "certifying a new composition replaces the old certified generation atomically" do
      cluster =
        Cluster.create!(composition_version: 1)

      first =
        create_certified_generation(
          cluster: cluster,
          facts: [
            fact("first", received_height: @height)
          ]
        )

      cluster.update!(composition_version: 2)

      second =
        GenerationBuilder.call(
          cluster_id: cluster.id,
          composition_version: 2,
          checkpoint_height: @height,
          checkpoint_hash: @block_hash,
          facts: [
            fact("second", spent_height: @height)
          ]
        )

      result =
        Certifier.call(second)

      assert_equal true, result.ok
      assert_equal "replaced", first.reload.status
      assert_equal "certified", second.reload.status
      assert_equal(
        [second.id],
        ClusterTransactionProjectionGeneration
          .where(cluster_id: cluster.id, status: "certified")
          .pluck(:id)
      )
    end

    test "failed replacement leaves previous certified generation published" do
      cluster =
        Cluster.create!(composition_version: 1)

      first =
        create_certified_generation(
          cluster: cluster,
          facts: [
            fact("first-failure", received_height: @height)
          ]
        )

      cluster.update!(composition_version: 2)

      second =
        GenerationBuilder.call(
          cluster_id: cluster.id,
          composition_version: 1,
          checkpoint_height: @height,
          checkpoint_hash: @block_hash,
          facts: [
            fact("second-failure", spent_height: @height)
          ]
        )

      result =
        Certifier.call(second)

      assert_equal false, result.ok
      assert_equal "certified", first.reload.status
      assert_equal "stale", second.reload.status
    end

    test "merger deduplicates txids and keeps minimum non null heights" do
      source_a =
        create_certified_generation(
          cluster: Cluster.create!(composition_version: 1),
          facts: [
            fact("only-a", received_height: @height - 5),
            fact("both", received_height: @height - 4),
            fact("cross", received_height: @height - 3)
          ]
        )

      source_b =
        create_certified_generation(
          cluster: Cluster.create!(composition_version: 1),
          facts: [
            fact("only-b", spent_height: @height - 5),
            fact(
              "both",
              received_height: @height - 7,
              spent_height: @height - 2
            ),
            fact("cross", spent_height: @height - 1)
          ]
        )

      target =
        Cluster.create!(composition_version: 4)

      result =
        Merger.call(
          target_cluster_id: target.id,
          target_composition_version: 4,
          checkpoint_height: @height,
          checkpoint_hash: @block_hash,
          source_generation_ids: [
            source_a.id,
            source_b.id
          ]
        )

      assert_equal true, result.ok

      generation =
        result.generation.reload

      assert_equal "certified", generation.status
      assert_equal 3, generation.inflow_count
      assert_equal 3, generation.outflow_count
      assert_equal 4, generation.tx_count

      both =
        ClusterTransactionFact.find_by!(
          projection_generation_id: generation.id,
          txid: Txid.pack(txid("both"))
        )

      assert_equal @height - 7, both.received_height
      assert_equal @height - 2, both.spent_height
      assert_equal "replaced", source_a.reload.status
      assert_equal "replaced", source_b.reload.status
    end

    test "failed merge does not publish partial replacement" do
      source =
        create_certified_generation(
          cluster: Cluster.create!(composition_version: 1),
          facts: [
            fact("only-source", received_height: @height)
          ]
        )

      target =
        Cluster.create!(composition_version: 2)

      result =
        Merger.call(
          target_cluster_id: target.id,
          target_composition_version: 1,
          checkpoint_height: @height,
          checkpoint_hash: @block_hash,
          source_generation_ids: [source.id]
        )

      assert_equal false, result.ok
      assert_equal :composition_mismatch, result.reason
      assert_equal "certified", source.reload.status
      assert_equal "stale", result.generation.reload.status
    end

    test "reorg invalidates generations above common height" do
      cluster =
        Cluster.create!(composition_version: 1)

      generation =
        create_certified_generation(
          cluster: cluster,
          facts: [
            fact("reorg", received_height: @height)
          ]
        )

      ClusterTransactionProjectionBlock.create!(
        block_height: @height,
        block_hash: @block_hash,
        status: "projected",
        completed_at: Time.current
      )

      result =
        ReorgInvalidator.call(
          common_height: @height - 1,
          reason: "hash_mismatch"
        )

      assert_equal 1, result.fetch(:generations)
      assert_equal 1, result.fetch(:blocks)
      assert_equal "stale", generation.reload.status
      assert_equal "hash_mismatch", generation.stale_reason
      assert_equal(
        :stale,
        Readiness.call(
          cluster_id: cluster.id,
          cluster_checkpoint: @height,
          composition_version: 1
        ).status
      )
    end

    private

    def create_certified_generation(cluster:, facts:)
      create_cluster_checkpoint(@height, @block_hash)

      generation =
        GenerationBuilder.call(
          cluster_id: cluster.id,
          composition_version: cluster.composition_version,
          checkpoint_height: @height,
          checkpoint_hash: @block_hash,
          facts: facts
        )

      result =
        Certifier.call(generation)

      assert_equal true, result.ok

      generation.reload
    end

    def create_cluster_checkpoint(height, block_hash)
      ClusterProcessedBlock.find_or_create_by!(
        height: height
      ) do |block|
        block.block_hash = block_hash
        block.status = "processed"
        block.processed_at = Time.current
      end
    end

    def create_projection_chain(height, final_hash)
      (0..height).each do |block_height|
        ClusterTransactionProjectionBlock.find_or_create_by!(
          block_height: block_height
        ) do |block|
          block.block_hash =
            block_height == height ? final_hash : unique_hash("projection")
          block.status = "projected"
          block.completed_at = Time.current
        end
      end
    end

    def fact(label, received_height: nil, spent_height: nil)
      {
        txid: txid(label),
        received_height: received_height,
        spent_height: spent_height
      }
    end

    def txid(label)
      Digest::SHA256.hexdigest(label)
    end

    def unique_hash(label)
      Digest::SHA256.hexdigest(
        "#{label}-#{SecureRandom.hex(8)}"
      )
    end
  end
end
