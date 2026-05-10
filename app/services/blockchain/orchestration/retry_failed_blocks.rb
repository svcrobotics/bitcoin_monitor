# frozen_string_literal: true

module Blockchain
  module Orchestration
    class RetryFailedBlocks
      DEFAULT_LIMIT = ENV.fetch("LAYER1_RETRY_FAILED_LIMIT", 5).to_i

      def call(limit: DEFAULT_LIMIT)
        started_at = Time.current

        rows = ActiveRecord::Base.connection.exec_query(
          ActiveRecord::Base.sanitize_sql_array([
            "SELECT id, height FROM block_buffers WHERE status = ? ORDER BY updated_at ASC LIMIT ?",
            "failed",
            limit.to_i
          ])
        ).to_a

        if rows.empty?
          return result(
            ok: true,
            retried_count: 0,
            heights: [],
            started_at: started_at
          )
        end

        ids = rows.map { |row| row["id"].to_i }
        heights = rows.map { |row| row["height"].to_i }

        ActiveRecord::Base.connection.execute(
          ActiveRecord::Base.sanitize_sql_array([
            "UPDATE block_buffers SET status = ?, updated_at = NOW() WHERE id IN (?)",
            "pending",
            ids
          ])
        )

        result(
          ok: true,
          retried_count: rows.size,
          heights: heights,
          started_at: started_at
        )
      end

      private

      def result(**attrs)
        finished_at = Time.current

        attrs.merge(
          finished_at: finished_at,
          duration_ms: ((finished_at - attrs[:started_at]) * 1000).round)
      end
    end
  end
end