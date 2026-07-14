# frozen_string_literal: true

module Layer1
  class StrictOutputFacts
    def self.call(height:)
      new(height: height).call
    end

    def initialize(height:)
      @height = height.to_i
    end

    def call
      raise(
        ArgumentError,
        "height must be positive"
      ) unless height.positive?

      row =
        connection.select_one(
          strict_facts_sql
        )

      {
        height: height,

        outputs_count:
          row.fetch(
            "outputs_count",
            0
          ).to_i,

        outputs_value_btc:
          BigDecimal(
            row.fetch(
              "outputs_value_btc",
              "0"
            ).to_s
          ),

        live_outputs_count:
          row.fetch(
            "live_outputs_count",
            0
          ).to_i,

        live_outputs_value_btc:
          BigDecimal(
            row.fetch(
              "live_outputs_value_btc",
              "0"
            ).to_s
          ),

        spent_outputs_count:
          row.fetch(
            "spent_outputs_count",
            0
          ).to_i,

        spent_outputs_value_btc:
          BigDecimal(
            row.fetch(
              "spent_outputs_value_btc",
              "0"
            ).to_s
          ),

        overlapping_state_count:
          row.fetch(
            "overlapping_state_count",
            0
          ).to_i,

        conflicting_amounts_count:
          row.fetch(
            "conflicting_amounts_count",
            0
          ).to_i
      }
    end

    private

    attr_reader :height

    def connection
      ActiveRecord::Base.connection
    end

    def strict_facts_sql
      <<~SQL
        WITH candidates AS (
          SELECT
            txid,
            vout,
            amount_btc,
            TRUE AS is_live,
            FALSE AS is_spent

          FROM utxo_outputs

          WHERE block_height =
                #{height}

          UNION ALL

          SELECT
            txid,
            vout,
            amount_btc,
            FALSE AS is_live,
            TRUE AS is_spent

          FROM cluster_inputs

          WHERE block_height =
                #{height}
        ),

        grouped AS (
          SELECT
            txid,
            vout,

            MIN(amount_btc)
              AS min_amount_btc,

            MAX(amount_btc)
              AS max_amount_btc,

            BOOL_OR(is_live)
              AS is_live,

            BOOL_OR(is_spent)
              AS is_spent

          FROM candidates

          GROUP BY
            txid,
            vout
        )

        SELECT
          COUNT(*)
            AS outputs_count,

          COALESCE(
            SUM(max_amount_btc),
            0
          )
            AS outputs_value_btc,

          COUNT(*) FILTER (
            WHERE is_live
              AND NOT is_spent
          )
            AS live_outputs_count,

          COALESCE(
            SUM(max_amount_btc) FILTER (
              WHERE is_live
                AND NOT is_spent
            ),
            0
          )
            AS live_outputs_value_btc,

          COUNT(*) FILTER (
            WHERE is_spent
          )
            AS spent_outputs_count,

          COALESCE(
            SUM(max_amount_btc) FILTER (
              WHERE is_spent
            ),
            0
          )
            AS spent_outputs_value_btc,

          COUNT(*) FILTER (
            WHERE is_live
              AND is_spent
          )
            AS overlapping_state_count,

          COUNT(*) FILTER (
            WHERE min_amount_btc
                  IS DISTINCT FROM
                  max_amount_btc
          )
            AS conflicting_amounts_count

        FROM grouped
      SQL
    end
  end
end
