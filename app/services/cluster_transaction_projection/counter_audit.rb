# frozen_string_literal: true

module ClusterTransactionProjection
  class CounterAudit
    def self.call(generation)
      new(generation).call
    end

    def self.compute_counts(generation)
      new(generation).compute_counts
    end

    def initialize(generation)
      @generation =
        generation.is_a?(
          ClusterTransactionProjectionGeneration
        ) ? generation : ClusterTransactionProjectionGeneration.find(generation)
    end

    def call
      actual = compute_counts

      expected = {
        inflow_count: generation.inflow_count.to_i,
        outflow_count: generation.outflow_count.to_i,
        tx_count: generation.tx_count.to_i,
        facts_count: generation.facts_count.to_i
      }

      Result.new(
        ok: expected == actual,
        expected: expected,
        actual: actual
      )
    end

    def compute_counts
      sql = <<~SQL.squish
        SELECT
          COUNT(*) FILTER (
            WHERE received_height IS NOT NULL
              AND received_height <= :checkpoint
          ) AS inflow_count,

          COUNT(*) FILTER (
            WHERE spent_height IS NOT NULL
              AND spent_height <= :checkpoint
          ) AS outflow_count,

          COUNT(*) FILTER (
            WHERE (
              received_height IS NOT NULL
              AND received_height <= :checkpoint
            ) OR (
              spent_height IS NOT NULL
              AND spent_height <= :checkpoint
            )
          ) AS tx_count,

          COUNT(*) AS facts_count
        FROM cluster_transaction_facts
        WHERE projection_generation_id = :generation_id
      SQL

      row =
        ActiveRecord::Base.connection.select_one(
          ActiveRecord::Base.sanitize_sql_array(
            [
              sql,
              {
                checkpoint: generation.checkpoint_height.to_i,
                generation_id: generation.id
              }
            ]
          )
        )

      {
        inflow_count: row["inflow_count"].to_i,
        outflow_count: row["outflow_count"].to_i,
        tx_count: row["tx_count"].to_i,
        facts_count: row["facts_count"].to_i
      }
    end

    Result = Struct.new(
      :ok,
      :expected,
      :actual,
      keyword_init: true
    )

    private

    attr_reader :generation
  end
end
