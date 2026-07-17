# frozen_string_literal: true

require "bigdecimal"

module ActorBehaviors
  module Heavy
    class SweepRelationEvidence
      VERSION =
        "sweep_relation_evidence_v1"

      DEFAULT_TIMEOUT_MS =
        300_000

      def self.call(
        source_cluster_id:,
        from_height:,
        to_height:
      )
        new(
          source_cluster_id:
            source_cluster_id,

          from_height:
            from_height,

          to_height:
            to_height
        ).call
      end

      def initialize(
        source_cluster_id:,
        from_height:,
        to_height:
      )
        @source_cluster_id =
          source_cluster_id.to_i

        @from_height =
          from_height.to_i

        @to_height =
          to_height.to_i
      end

      def call
        unless Cluster.exists?(
          id: source_cluster_id
        )
          return deferred(
            :source_cluster_missing
          )
        end

        started_at =
          Process.clock_gettime(
            Process::CLOCK_MONOTONIC
          )

        row = nil

        connection.transaction(
          requires_new: true
        ) do
          timeout_ms =
            ENV.fetch(
              "ACTOR_BEHAVIOR_HEAVY_SWEEP_TIMEOUT_MS",
              ENV.fetch(
                "ACTOR_BEHAVIOR_HEAVY_TIMEOUT_MS",
                DEFAULT_TIMEOUT_MS.to_s
              )
            ).to_i.clamp(
              10_000,
              900_000
            )

          connection.execute(
            "SET LOCAL statement_timeout = " \
            "#{connection.quote("#{timeout_ms}ms")}"
          )

          connection.execute(
            "SET LOCAL lock_timeout = '2s'"
          )

          row =
            connection
              .exec_query(sql)
              .first
        end

        duration_seconds =
          (
            Process.clock_gettime(
              Process::CLOCK_MONOTONIC
            ) - started_at
          ).round(3)

        unless row
          return deferred(
            :no_sweep_activity
          )
        end

        consolidation_transactions =
          row[
            "consolidation_transactions"
          ].to_i

        if consolidation_transactions.zero?
          return deferred(
            :no_sweep_activity
          )
        end

        destination_cluster_id =
          row[
            "top_destination_cluster_id"
          ]&.to_i

        unless destination_cluster_id
          return deferred(
            :no_clustered_destination
          )
        end

        {
          ok: true,
          status: "certified",

          evidence: {
            analysis_version:
              VERSION,

            duration_seconds:
              duration_seconds,

            source_cluster_id:
              source_cluster_id,

            window_from_height:
              from_height,

            window_to_height:
              to_height,

            consolidation_transactions:
              consolidation_transactions,

            consolidation_blocks:
              row[
                "consolidation_blocks"
              ].to_i,

            first_consolidation_height:
              row[
                "first_consolidation_height"
              ].to_i,

            last_consolidation_height:
              row[
                "last_consolidation_height"
              ].to_i,

            source_input_rows:
              row[
                "source_input_rows"
              ].to_i,

            source_input_btc:
              decimal_string(
                row[
                  "source_input_btc"
                ]
              ),

            output_rows:
              row[
                "output_rows"
              ].to_i,

            total_output_btc:
              decimal_string(
                row[
                  "total_output_btc"
                ]
              ),

            same_cluster_btc:
              decimal_string(
                row[
                  "same_cluster_btc"
                ]
              ),

            external_cluster_btc:
              decimal_string(
                row[
                  "external_cluster_btc"
                ]
              ),

            unclustered_btc:
              decimal_string(
                row[
                  "unclustered_btc"
                ]
              ),

            non_address_btc:
              decimal_string(
                row[
                  "non_address_btc"
                ]
              ),

            distinct_external_clusters:
              row[
                "distinct_external_clusters"
              ].to_i,

            top_destination_cluster_id:
              destination_cluster_id,

            top_destination_transactions:
              row[
                "top_destination_transactions"
              ].to_i,

            top_destination_received_btc:
              decimal_string(
                row[
                  "top_destination_received_btc"
                ]
              ),

            top_destination_share_percent:
              decimal_string(
                row[
                  "top_destination_share_percent"
                ]
              )
          }
        }
      rescue ActiveRecord::QueryCanceled
        deferred(
          :statement_timeout
        ).merge(
          stage:
            :sweep_query
        )
      rescue StandardError => error
        {
          ok: false,
          status: "failed",
          reason: :calculation_failed,
          error_class: error.class.name,
          error_message: error.message,
          evidence: {}
        }
      end

      private

      attr_reader(
        :source_cluster_id,
        :from_height,
        :to_height
      )

      def connection
        ActiveRecord::Base.connection
      end

      def sql
        <<~SQL
          WITH window_inputs AS MATERIALIZED (
            SELECT
              address,
              spent_txid,
              spent_block_height,
              amount_btc

            FROM cluster_inputs

            WHERE spent_txid IS NOT NULL

              AND spent_block_height
                BETWEEN #{from_height}
                    AND #{to_height}
          ),

          source_addresses AS MATERIALIZED (
            SELECT address
            FROM addresses
            WHERE cluster_id =
              #{source_cluster_id}
          ),

          source_spends AS MATERIALIZED (
            SELECT
              input.spent_txid,
              input.spent_block_height,

              COUNT(*) AS source_input_rows,

              COALESCE(
                SUM(input.amount_btc),
                0
              ) AS source_input_btc

            FROM window_inputs input

            INNER JOIN source_addresses source
              ON source.address =
                 input.address

            GROUP BY
              input.spent_txid,
              input.spent_block_height
          ),

          output_candidates AS MATERIALIZED (
            SELECT
              output.txid,
              output.vout,
              output.address,
              output.amount_btc,
              1 AS source_priority

            FROM utxo_outputs output

            INNER JOIN source_spends spend
              ON spend.spent_txid =
                 output.txid

            UNION ALL

            SELECT
              spent_output.txid,
              spent_output.vout,
              spent_output.address,
              spent_output.amount_btc,
              0 AS source_priority

            FROM cluster_inputs spent_output

            INNER JOIN source_spends spend
              ON spend.spent_txid =
                 spent_output.txid
          ),

          strict_outputs AS MATERIALIZED (
            SELECT DISTINCT ON (
              txid,
              vout
            )
              txid,
              vout,
              address,
              amount_btc

            FROM output_candidates

            ORDER BY
              txid,
              vout,
              source_priority
          ),

          routed_outputs AS MATERIALIZED (
            SELECT
              spend.spent_txid,
              spend.spent_block_height,
              output.vout,
              output.address,
              output.amount_btc,

              destination.cluster_id
                AS destination_cluster_id,

              CASE
                WHEN output.address IS NULL
                  OR BTRIM(
                    output.address
                  ) = ''
                  THEN 'non_address_output'

                WHEN destination.cluster_id
                     IS NULL
                  THEN 'unclustered_destination'

                WHEN destination.cluster_id =
                     #{source_cluster_id}
                  THEN 'same_cluster'

                ELSE 'external_cluster'
              END AS route_type

            FROM source_spends spend

            INNER JOIN strict_outputs output
              ON output.txid =
                 spend.spent_txid

            LEFT JOIN addresses destination
              ON destination.address =
                 output.address
          ),

          source_summary AS MATERIALIZED (
            SELECT
              COUNT(
                DISTINCT spend.spent_txid
              ) AS consolidation_transactions,

              COUNT(
                DISTINCT
                spend.spent_block_height
              ) AS consolidation_blocks,

              MIN(
                spend.spent_block_height
              ) AS first_consolidation_height,

              MAX(
                spend.spent_block_height
              ) AS last_consolidation_height,

              SUM(
                spend.source_input_rows
              ) AS source_input_rows,

              COALESCE(
                SUM(
                  spend.source_input_btc
                ),
                0
              ) AS source_input_btc

            FROM source_spends spend
          ),

          route_summary AS MATERIALIZED (
            SELECT
              COUNT(*) AS output_rows,

              COALESCE(
                SUM(amount_btc),
                0
              ) AS total_output_btc,

              COALESCE(
                SUM(amount_btc)
                  FILTER (
                    WHERE route_type =
                      'same_cluster'
                  ),
                0
              ) AS same_cluster_btc,

              COALESCE(
                SUM(amount_btc)
                  FILTER (
                    WHERE route_type =
                      'external_cluster'
                  ),
                0
              ) AS external_cluster_btc,

              COALESCE(
                SUM(amount_btc)
                  FILTER (
                    WHERE route_type =
                      'unclustered_destination'
                  ),
                0
              ) AS unclustered_btc,

              COALESCE(
                SUM(amount_btc)
                  FILTER (
                    WHERE route_type =
                      'non_address_output'
                  ),
                0
              ) AS non_address_btc,

              COUNT(
                DISTINCT destination_cluster_id
              ) FILTER (
                WHERE route_type =
                  'external_cluster'
              ) AS distinct_external_clusters

            FROM routed_outputs
          ),

          destination_totals AS MATERIALIZED (
            SELECT
              destination_cluster_id,

              COUNT(
                DISTINCT spent_txid
              ) AS transactions,

              SUM(
                amount_btc
              ) AS received_btc

            FROM routed_outputs

            WHERE route_type =
              'external_cluster'

            GROUP BY destination_cluster_id
          ),

          ranked_destinations AS MATERIALIZED (
            SELECT
              destination.*,

              SUM(
                received_btc
              ) OVER () AS total_external_btc,

              ROW_NUMBER() OVER (
                ORDER BY
                  received_btc DESC,
                  transactions DESC,
                  destination_cluster_id
              ) AS destination_rank

            FROM destination_totals destination
          )

          SELECT
            source_summary.*,
            route_summary.*,

            top_destination.destination_cluster_id
              AS top_destination_cluster_id,

            top_destination.transactions
              AS top_destination_transactions,

            top_destination.received_btc
              AS top_destination_received_btc,

            CASE
              WHEN top_destination.total_external_btc > 0
                THEN ROUND(
                  (
                    top_destination.received_btc /
                    top_destination.total_external_btc *
                    100
                  )::numeric,
                  2
                )
              ELSE 0
            END AS top_destination_share_percent

          FROM source_summary

          CROSS JOIN route_summary

          LEFT JOIN ranked_destinations
            top_destination

            ON top_destination.destination_rank =
               1
        SQL
      end

      def decimal_string(value)
        BigDecimal(
          value.to_s.presence || "0"
        ).to_s("F")
      rescue ArgumentError
        "0"
      end

      def deferred(reason)
        {
          ok: true,
          status: "deferred",
          reason: reason,
          evidence: {}
        }
      end
    end
  end
end
