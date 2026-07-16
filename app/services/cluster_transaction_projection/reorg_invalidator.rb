# frozen_string_literal: true

module ClusterTransactionProjection
  class ReorgInvalidator
    def self.call(...)
      new(...).call
    end

    def initialize(common_height:, reason: "reorg")
      @common_height = common_height.to_i
      @reason = reason.to_s
    end

    def call
      now = Time.current

      ApplicationRecord.transaction do
        generations =
          ClusterTransactionProjectionGeneration
            .where("checkpoint_height > ?", common_height)
            .where.not(status: %w[stale replaced failed])

        blocks =
          ClusterTransactionProjectionBlock
            .where("block_height > ?", common_height)
            .where.not(status: %w[stale failed])

        generation_count =
          generations.update_all(
            status: "stale",
            stale_reason: reason,
            stale_at: now,
            updated_at: now
          )

        block_count =
          blocks.update_all(
            status: "stale",
            updated_at: now
          )

        {
          generations: generation_count,
          blocks: block_count
        }
      end
    end

    private

    attr_reader :common_height, :reason
  end
end
