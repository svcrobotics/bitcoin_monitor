# frozen_string_literal: true

module AddressSpendStats
  class NextRecord
    def self.call
      ClusterProcessedBlock
        .where(
          status: "processed"
        )
        .joins(
          <<~SQL.squish
            LEFT JOIN
              address_spend_projection_blocks
                AS spend_projection

              ON spend_projection.height =
                 cluster_processed_blocks.height
          SQL
        )
        .where(
          <<~SQL.squish,
            spend_projection.id IS NULL

            OR spend_projection.status =
               :pending

            OR (
              spend_projection.status =
                :failed

              AND spend_projection.attempts <
                  :max_attempts
            )

            OR (
              spend_projection.status =
                :processing

              AND spend_projection.attempts <
                  :max_attempts

              AND (
                spend_projection
                  .processing_started_at
                    IS NULL

                OR spend_projection
                     .processing_started_at <
                     :stale_before
              )
            )

            OR (
              spend_projection.status =
                :completed

              AND spend_projection.block_hash
                  <> cluster_processed_blocks.block_hash
            )
          SQL
          pending: "pending",
          failed: "failed",
          processing: "processing",
          completed: "completed",
          max_attempts:
            AddressSpendStats::Config.max_attempts,
          stale_before:
            AddressSpendStats::Config
              .processing_stale_after_seconds
              .seconds
              .ago
        )
        .order(
          "cluster_processed_blocks.height ASC"
        )
        .first
    end
  end
end
