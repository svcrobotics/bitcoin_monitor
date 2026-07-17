# frozen_string_literal: true

require "bigdecimal"
require "securerandom"

$stdout.sync = true
$stderr.sync = true

module ActorBehaviors
  module Heavy
    class DownstreamDistributionEvidence
      VERSION =
        "downstream_distribution_evidence_v1"

      DEFAULT_TIMEOUT_MS =
        300_000

      DEFAULT_MAX_SOURCE_TRANSACTIONS =
        1_000

      DEFAULT_MAX_STRICT_OUTPUT_ROWS =
        100_000

      def self.call(
        cluster_id:,
        from_height:,
        to_height:
      )
        new(
          cluster_id:
            cluster_id,

          from_height:
            from_height,

          to_height:
            to_height
        ).call
      end

      def initialize(
        cluster_id:,
        from_height:,
        to_height:
      )
        @cluster_id =
          cluster_id.to_i

        @from_height =
          from_height.to_i

        @to_height =
          to_height.to_i

        @token =
          SecureRandom.hex(6)

        @current_stage = nil
        @stage_durations = {}

        @max_source_transactions =
          ENV.fetch(
            "ACTOR_BEHAVIOR_HEAVY_MAX_SOURCE_TRANSACTIONS",
            DEFAULT_MAX_SOURCE_TRANSACTIONS.to_s
          ).to_i.clamp(
            100,
            100_000
          )

        @max_strict_output_rows =
          ENV.fetch(
            "ACTOR_BEHAVIOR_HEAVY_MAX_STRICT_OUTPUT_ROWS",
            DEFAULT_MAX_STRICT_OUTPUT_ROWS.to_s
          ).to_i.clamp(
            10_000,
            2_000_000
          )
      end

      def call
        unless Cluster.exists?(
          id: cluster_id
        )
          return deferred(
            :downstream_cluster_missing
          )
        end

        result = nil
        source_transaction_count = 0
        strict_output_rows = 0

        connection.transaction(
          requires_new: true
        ) do
          configure_transaction

          run_stage(
            :source_addresses
          ) do
            create_source_addresses
          end

          run_stage(
            :window_inputs
          ) do
            create_window_inputs
          end

          run_stage(
            :source_spends
          ) do
            create_source_spends
          end

          source_transaction_count =
            table_count(
              source_spends_table
            )

          if source_transaction_count.zero?
            result =
              deferred(
                :no_distribution_activity
              )

            next
          end

          if source_transaction_count >
             max_source_transactions
            result =
              deferred(
                :distribution_scope_too_large
              ).merge(
                stage:
                  :source_spends,

                scope_counts: {
                  source_transactions:
                    source_transaction_count,

                  maximum_source_transactions:
                    max_source_transactions
                },

                stage_durations_seconds:
                  stage_durations
              )

            next
          end

          run_stage(
            :spend_transactions
          ) do
            create_spend_transactions
          end

          run_stage(
            :all_input_stats
          ) do
            create_all_input_stats
          end

          run_stage(
            :strict_outputs
          ) do
            create_strict_outputs
          end

          strict_output_rows =
            table_count(
              strict_outputs_table
            )

          if strict_output_rows >
             max_strict_output_rows
            result =
              deferred(
                :distribution_scope_too_large
              ).merge(
                stage:
                  :strict_outputs,

                scope_counts: {
                  source_transactions:
                    source_transaction_count,

                  strict_output_rows:
                    strict_output_rows,

                  maximum_strict_output_rows:
                    max_strict_output_rows
                },

                stage_durations_seconds:
                  stage_durations
              )

            next
          end

          run_stage(
            :output_address_clusters
          ) do
            create_output_address_clusters
          end

          run_stage(
            :routed_outputs
          ) do
            create_routed_outputs
          end

          summary =
            run_stage(
              :summary
            ) do
              connection
                .exec_query(
                  summary_sql
                )
                .first
            end

          unless summary
            result =
              deferred(
                :distribution_summary_missing
              )

            next
          end

          destinations =
            run_stage(
              :destinations
            ) do
              connection
                .exec_query(
                  destinations_sql
                )
                .to_a
                .map do |row|
                  destination_evidence(row)
                end
            end

          result = {
            ok: true,
            status: "certified",

            evidence:
              summary_evidence(
                summary
              ).merge(
                top_destinations:
                  destinations,

                stage_durations_seconds:
                  stage_durations,

                scope_counts: {
                  source_transactions:
                    source_transaction_count,

                  strict_output_rows:
                    strict_output_rows
                }
              )
          }
        end

        result
      rescue ActiveRecord::QueryCanceled
        deferred(
          :statement_timeout
        ).merge(
          stage:
            current_stage,

          stage_durations_seconds:
            stage_durations
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
        :cluster_id,
        :from_height,
        :to_height,
        :token
      )

      def connection
        ActiveRecord::Base.connection
      end

      attr_reader(
        :current_stage,
        :stage_durations,
        :max_source_transactions,
        :max_strict_output_rows
      )

      def run_stage(name)
        @current_stage =
          name

        started_at =
          Process.clock_gettime(
            Process::CLOCK_MONOTONIC
          )

        puts
        puts(
          "===== Heavy distribution: "           "#{name} ====="
        )

        result =
          yield

        duration =
          Process.clock_gettime(
            Process::CLOCK_MONOTONIC
          ) - started_at

        stage_durations[
          name.to_s
        ] =
          duration.round(3)

        puts(
          "Terminé en "           "#{duration.round(2)} s"
        )

        result
      end

      def configure_transaction
        timeout_ms =
          ENV.fetch(
            "ACTOR_BEHAVIOR_HEAVY_TIMEOUT_MS",
            DEFAULT_TIMEOUT_MS.to_s
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
      end

      def create_source_addresses
        connection.execute(
          <<~SQL
            CREATE TEMP TABLE
              #{source_addresses_table}
            ON COMMIT DROP
            AS

            SELECT
              address

            FROM addresses

            WHERE cluster_id =
              #{cluster_id}

              AND address IS NOT NULL

              AND BTRIM(address) <> ''
          SQL
        )

        connection.execute(
          <<~SQL
            CREATE UNIQUE INDEX
              #{index_name("source_addresses")}
            ON #{source_addresses_table} (
              address
            );

            ANALYZE #{source_addresses_table}
          SQL
        )
      end

      def create_window_inputs
        connection.execute(
          <<~SQL
            CREATE TEMP TABLE
              #{window_inputs_table}
            ON COMMIT DROP
            AS

            SELECT
              address,
              txid,
              vout,
              amount_btc,
              block_height,
              spent_txid,
              spent_block_height

            FROM cluster_inputs

            WHERE spent_block_height
              BETWEEN #{from_height}
                  AND #{to_height}

              AND spent_txid IS NOT NULL
          SQL
        )

        connection.execute(
          <<~SQL
            CREATE INDEX
              #{index_name("window_address")}
            ON #{window_inputs_table} (
              address
            );

            CREATE INDEX
              #{index_name("window_spent")}
            ON #{window_inputs_table} (
              spent_block_height,
              spent_txid
            );

            ANALYZE #{window_inputs_table}
          SQL
        )
      end

      def create_source_spends
        connection.execute(
          <<~SQL
            CREATE TEMP TABLE
              #{source_spends_table}
            ON COMMIT DROP
            AS

            SELECT
              input.spent_txid,
              input.spent_block_height,

              COUNT(*) AS source_input_rows,

              COALESCE(
                SUM(input.amount_btc),
                0
              ) AS source_input_btc

            FROM #{window_inputs_table} input

            INNER JOIN
              #{source_addresses_table} source

              ON source.address =
                 input.address

            GROUP BY
              input.spent_txid,
              input.spent_block_height
          SQL
        )

        connection.execute(
          <<~SQL
            CREATE UNIQUE INDEX
              #{index_name("source_spends")}
            ON #{source_spends_table} (
              spent_txid
            );

            ANALYZE #{source_spends_table}
          SQL
        )
      end

      def create_spend_transactions
        connection.execute(
          <<~SQL
            CREATE TEMP TABLE
              #{spend_transactions_table}
            ON COMMIT DROP
            AS

            SELECT
              spent_txid,
              spent_block_height

            FROM #{source_spends_table};

            CREATE UNIQUE INDEX
              #{index_name("spend_transactions")}
            ON #{spend_transactions_table} (
              spent_txid
            );

            ANALYZE #{spend_transactions_table}
          SQL
        )
      end

      def create_all_input_stats
        connection.execute(
          <<~SQL
            CREATE TEMP TABLE
              #{all_input_stats_table}
            ON COMMIT DROP
            AS

            SELECT
              transaction.spent_txid,

              COUNT(*) AS all_input_rows

            FROM #{spend_transactions_table}
              transaction

            INNER JOIN #{window_inputs_table}
              input

              ON input.spent_block_height =
                 transaction.spent_block_height

             AND input.spent_txid =
                 transaction.spent_txid

            GROUP BY
              transaction.spent_txid;

            CREATE UNIQUE INDEX
              #{index_name("all_inputs")}
            ON #{all_input_stats_table} (
              spent_txid
            );

            ANALYZE #{all_input_stats_table}
          SQL
        )
      end

      def create_strict_outputs
        connection.execute(
          <<~SQL
            CREATE TEMP TABLE
              #{strict_outputs_table}
            ON COMMIT DROP
            AS

            SELECT DISTINCT ON (
              candidate.txid,
              candidate.vout
            )
              candidate.txid,
              candidate.vout,
              candidate.address,
              candidate.amount_btc

            FROM (
              SELECT
                output.txid,
                output.vout,
                output.address,
                output.amount_btc,
                1 AS source_priority

              FROM #{spend_transactions_table}
                transaction

              INNER JOIN utxo_outputs output
                ON output.txid =
                   transaction.spent_txid

              UNION ALL

              SELECT
                output.txid,
                output.vout,
                output.address,
                output.amount_btc,
                0 AS source_priority

              FROM #{spend_transactions_table}
                transaction

              INNER JOIN cluster_inputs output
                ON output.txid =
                   transaction.spent_txid
            ) candidate

            ORDER BY
              candidate.txid,
              candidate.vout,
              candidate.source_priority;

            CREATE INDEX
              #{index_name("strict_outputs")}
            ON #{strict_outputs_table} (
              txid
            );

            ANALYZE #{strict_outputs_table}
          SQL
        )
      end

      def create_output_address_clusters
        connection.execute(
          <<~SQL
            CREATE TEMP TABLE
              #{output_address_clusters_table}
            ON COMMIT DROP
            AS

            SELECT
              output_address.address,

              destination.cluster_id
                AS destination_cluster_id

            FROM (
              SELECT DISTINCT
                output.address

              FROM #{strict_outputs_table} output

              WHERE output.address IS NOT NULL
                AND BTRIM(output.address) <> ''
            ) output_address

            LEFT JOIN addresses destination
              ON destination.address =
                 output_address.address;

            CREATE UNIQUE INDEX
              #{index_name("output_address_clusters")}
            ON #{output_address_clusters_table} (
              address
            );

            ANALYZE #{output_address_clusters_table}
          SQL
        )
      end

      def create_routed_outputs
        connection.execute(
          <<~SQL
            CREATE TEMP TABLE
              #{routed_outputs_table}
            ON COMMIT DROP
            AS

            SELECT
              spend.spent_txid,
              spend.spent_block_height,

              output.vout,
              output.address,
              output.amount_btc,

              destination.destination_cluster_id
                AS destination_cluster_id,

              CASE
                WHEN output.address IS NULL
                  OR BTRIM(
                    output.address
                  ) = ''
                  THEN 'non_address_output'

                WHEN destination.destination_cluster_id
                     IS NULL
                  THEN 'unclustered_destination'

                WHEN destination.destination_cluster_id =
                     #{cluster_id}
                  THEN 'same_cluster'

                ELSE 'external_cluster'
              END AS route_type

            FROM #{source_spends_table} spend

            INNER JOIN
              #{strict_outputs_table} output

              ON output.txid =
                 spend.spent_txid

            LEFT JOIN
              #{output_address_clusters_table}
              destination

              ON destination.address =
                 output.address;

            CREATE INDEX
              #{index_name("routed_txid")}
            ON #{routed_outputs_table} (
              spent_txid
            );

            ANALYZE #{routed_outputs_table}
          SQL
        )
      end

      def summary_sql
        <<~SQL
          WITH transaction_outputs AS (
            SELECT
              spent_txid,

              COUNT(*) AS output_rows

            FROM #{routed_outputs_table}

            GROUP BY spent_txid
          ),

          transaction_metrics AS (
            SELECT
              spend.spent_txid,
              spend.spent_block_height,
              spend.source_input_rows,
              inputs.all_input_rows,
              outputs.output_rows

            FROM #{source_spends_table} spend

            INNER JOIN
              #{all_input_stats_table} inputs

              ON inputs.spent_txid =
                 spend.spent_txid

            LEFT JOIN transaction_outputs outputs
              ON outputs.spent_txid =
                 spend.spent_txid
          ),

          route_summary AS (
            SELECT
              COUNT(
                DISTINCT address
              ) FILTER (
                WHERE route_type IN (
                  'external_cluster',
                  'unclustered_destination'
                )
              ) AS distinct_external_addresses,

              COUNT(
                DISTINCT destination_cluster_id
              ) FILTER (
                WHERE route_type =
                  'external_cluster'
              ) AS distinct_external_clusters,

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
              ) AS unclustered_btc

            FROM #{routed_outputs_table}
          ),

          destination_totals AS (
            SELECT
              destination_cluster_id,

              SUM(
                amount_btc
              ) AS received_btc

            FROM #{routed_outputs_table}

            WHERE route_type =
              'external_cluster'

            GROUP BY destination_cluster_id
          ),

          ranked_destinations AS (
            SELECT
              destination.*,

              ROW_NUMBER() OVER (
                ORDER BY
                  received_btc DESC,
                  destination_cluster_id
              ) AS destination_rank

            FROM destination_totals destination
          )

          SELECT
            COUNT(*) AS spending_transactions,

            COUNT(
              DISTINCT spent_block_height
            ) AS spending_blocks,

            MIN(
              spent_block_height
            ) AS first_spent_height,

            MAX(
              spent_block_height
            ) AS last_spent_height,

            COUNT(*) FILTER (
              WHERE all_input_rows >
                    source_input_rows
            ) AS mixed_input_transactions,

            COUNT(*) FILTER (
              WHERE output_rows IS NULL
            ) AS missing_output_transactions,

            ROUND(
              AVG(
                COALESCE(
                  output_rows,
                  0
                )
              )::numeric,
              2
            ) AS average_outputs_per_transaction,

            ROUND(
              PERCENTILE_CONT(0.5)
                WITHIN GROUP (
                  ORDER BY COALESCE(
                    output_rows,
                    0
                  )
                )::numeric,
              2
            ) AS median_outputs_per_transaction,

            ROUND(
              PERCENTILE_CONT(0.9)
                WITHIN GROUP (
                  ORDER BY COALESCE(
                    output_rows,
                    0
                  )
                )::numeric,
              2
            ) AS p90_outputs_per_transaction,

            COUNT(*) FILTER (
              WHERE COALESCE(
                output_rows,
                0
              ) >= 5
            ) AS batch_transactions,

            ROUND(
              (
                100.0 *
                COUNT(*) FILTER (
                  WHERE COALESCE(
                    output_rows,
                    0
                  ) >= 5
                ) /
                NULLIF(
                  COUNT(*),
                  0
                )
              )::numeric,
              2
            ) AS batch_transaction_percent,

            route_summary.*,

            route_summary.external_cluster_btc +
            route_summary.unclustered_btc
              AS total_external_btc,

            ROUND(
              (
                100.0 *
                route_summary.unclustered_btc /
                NULLIF(
                  route_summary.external_cluster_btc +
                  route_summary.unclustered_btc,
                  0
                )
              )::numeric,
              2
            ) AS unclustered_external_percent,

            top_destination.destination_cluster_id
              AS top_destination_cluster_id,

            ROUND(
              (
                100.0 *
                top_destination.received_btc /
                NULLIF(
                  route_summary.external_cluster_btc +
                  route_summary.unclustered_btc,
                  0
                )
              )::numeric,
              2
            ) AS top_destination_share_percent

          FROM transaction_metrics

          CROSS JOIN route_summary

          LEFT JOIN ranked_destinations
            top_destination

            ON top_destination.destination_rank =
               1

          GROUP BY
            route_summary.distinct_external_addresses,
            route_summary.distinct_external_clusters,
            route_summary.same_cluster_btc,
            route_summary.external_cluster_btc,
            route_summary.unclustered_btc,
            top_destination.destination_cluster_id,
            top_destination.received_btc
        SQL
      end

      def destinations_sql
        <<~SQL
          SELECT
            destination_cluster_id,

            COUNT(
              DISTINCT spent_txid
            ) AS transactions,

            COUNT(*) AS output_rows,

            COUNT(
              DISTINCT address
            ) AS destination_addresses,

            SUM(
              amount_btc
            ) AS received_btc

          FROM #{routed_outputs_table}

          WHERE route_type =
            'external_cluster'

          GROUP BY destination_cluster_id

          ORDER BY
            received_btc DESC,
            destination_cluster_id

          LIMIT 10
        SQL
      end

      def summary_evidence(row)
        {
          analysis_version:
            VERSION,

          cluster_id:
            cluster_id,

          window_from_height:
            from_height,

          window_to_height:
            to_height,

          spending_transactions:
            row[
              "spending_transactions"
            ].to_i,

          spending_blocks:
            row[
              "spending_blocks"
            ].to_i,

          first_spent_height:
            row[
              "first_spent_height"
            ].to_i,

          last_spent_height:
            row[
              "last_spent_height"
            ].to_i,

          mixed_input_transactions:
            row[
              "mixed_input_transactions"
            ].to_i,

          missing_output_transactions:
            row[
              "missing_output_transactions"
            ].to_i,

          average_outputs_per_transaction:
            decimal_string(
              row[
                "average_outputs_per_transaction"
              ]
            ),

          median_outputs_per_transaction:
            decimal_string(
              row[
                "median_outputs_per_transaction"
              ]
            ),

          p90_outputs_per_transaction:
            decimal_string(
              row[
                "p90_outputs_per_transaction"
              ]
            ),

          batch_transactions:
            row[
              "batch_transactions"
            ].to_i,

          batch_transaction_percent:
            decimal_string(
              row[
                "batch_transaction_percent"
              ]
            ),

          distinct_external_addresses:
            row[
              "distinct_external_addresses"
            ].to_i,

          distinct_external_clusters:
            row[
              "distinct_external_clusters"
            ].to_i,

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

          total_external_btc:
            decimal_string(
              row[
                "total_external_btc"
              ]
            ),

          unclustered_external_percent:
            decimal_string(
              row[
                "unclustered_external_percent"
              ]
            ),

          top_destination_cluster_id:
            row[
              "top_destination_cluster_id"
            ]&.to_i,

          top_destination_share_percent:
            decimal_string(
              row[
                "top_destination_share_percent"
              ]
            )
        }
      end

      def destination_evidence(row)
        {
          destination_cluster_id:
            row[
              "destination_cluster_id"
            ].to_i,

          transactions:
            row[
              "transactions"
            ].to_i,

          output_rows:
            row[
              "output_rows"
            ].to_i,

          destination_addresses:
            row[
              "destination_addresses"
            ].to_i,

          received_btc:
            decimal_string(
              row[
                "received_btc"
              ]
            )
        }
      end

      def table_count(table)
        connection
          .select_value(
            "SELECT COUNT(*) FROM #{table}"
          )
          .to_i
      end

      def table_name(suffix)
        connection.quote_table_name(
          "tmp_abh_#{token}_#{suffix}"
        )
      end

      def index_name(suffix)
        connection.quote_column_name(
          "idx_abh_#{token}_#{suffix}"
        )
      end

      def source_addresses_table
        table_name(
          "source_addresses"
        )
      end

      def window_inputs_table
        table_name(
          "window_inputs"
        )
      end

      def source_spends_table
        table_name(
          "source_spends"
        )
      end

      def spend_transactions_table
        table_name(
          "spend_transactions"
        )
      end

      def all_input_stats_table
        table_name(
          "all_input_stats"
        )
      end

      def strict_outputs_table
        table_name(
          "strict_outputs"
        )
      end

      def output_address_clusters_table
        table_name(
          "output_address_clusters"
        )
      end

      def routed_outputs_table
        table_name(
          "routed_outputs"
        )
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
