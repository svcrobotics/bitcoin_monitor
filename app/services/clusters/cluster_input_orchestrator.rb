# frozen_string_literal: true

module Clusters
  class ClusterInputOrchestrator
    DEFAULT_BATCH_BLOCKS = ENV.fetch("CLUSTER_INPUT_ORCHESTRATOR_BLOCKS", "10").to_i

    def self.call(limit_blocks: DEFAULT_BATCH_BLOCKS)
      new(limit_blocks: limit_blocks).call
    end

    def initialize(limit_blocks:)
      @limit_blocks = limit_blocks.to_i
    end

    def call
      cursor = ClusterInputCursor.first_or_create!(last_height_processed: 0)

      best_height = BlockBufferModel
        .where(status: "processed")
        .maximum(:height)
        .to_i

      existing_max_height = ClusterInput.maximum(:spent_block_height).to_i
      effective_cursor = [cursor.last_height_processed.to_i, existing_max_height].max

      if effective_cursor > cursor.last_height_processed.to_i
        cursor.update!(last_height_processed: effective_cursor)
      end

      from_height = cursor.last_height_processed.to_i + 1
      to_height = [from_height + @limit_blocks - 1, best_height].min

      return {
        ok: true,
        skipped: true,
        reason: "nothing_to_build",
        last_height_processed: cursor.last_height_processed,
        best_height: best_height
      } if from_height > to_height

      (from_height..to_height).each do |height|
        Clusters::ClusterInputBuildJob.perform_async(height, height)
      end

      cursor.update!(last_height_processed: to_height)

      {
        ok: true,
        from_height: from_height,
        to_height: to_height,
        enqueued: to_height - from_height + 1,
        best_height: best_height
      }
    end
  end
end
