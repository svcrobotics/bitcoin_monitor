# frozen_string_literal: true

module ActorBehaviors
  module Heavy
    module Service
      class SegmentedDirectDistributionEvidence <
        ActorBehaviors::Heavy::
          SegmentedDownstreamDistributionEvidence

        VERSION =
          "service_direct_distribution_segmented_source_first_v2"

        SCAN_STRATEGY =
          "source_first"

        private

        def process_window(window:, index:)
          @current_chunk = {
            index: index + 1,
            from_height: window.begin,
            to_height: window.end
          }

          prefix =
            format(
              "chunk_%02d",
              index + 1
            )

          tables =
            chunk_tables(prefix)

          run_stage(
            "#{prefix}_source_spends"
          ) do
            create_source_spends_source_first(
              table:
                tables.fetch(:source_spends),
              window:
                window
            )
          end

          source_transactions =
            table_count(
              tables.fetch(:source_spends)
            )

          if source_transactions.zero?
            record_empty_source_first_chunk(
              window:
                window
            )

            drop_chunk_tables(tables)
            return
          end

          source_input_rows =
            table_sum(
              table_name:
                tables.fetch(:source_spends),
              column_name:
                :source_input_rows
            )

          run_stage(
            "#{prefix}_all_input_stats"
          ) do
            create_all_input_stats_source_first(
              source_spends:
                tables.fetch(:source_spends),
              all_input_stats:
                tables.fetch(:all_input_stats)
            )
          end

          all_input_rows =
            table_sum(
              table_name:
                tables.fetch(:all_input_stats),
              column_name:
                :all_input_rows
            )

          run_stage(
            "#{prefix}_strict_outputs"
          ) do
            create_strict_outputs(
              source_spends:
                tables.fetch(:source_spends),
              strict_outputs:
                tables.fetch(:strict_outputs)
            )
          end

          strict_output_rows =
            table_count(
              tables.fetch(:strict_outputs)
            )

          run_stage(
            "#{prefix}_output_clusters"
          ) do
            create_output_address_clusters(
              strict_outputs:
                tables.fetch(:strict_outputs),
              output_clusters:
                tables.fetch(:output_clusters)
            )
          end

          run_stage(
            "#{prefix}_routed_outputs"
          ) do
            create_routed_outputs(
              source_spends:
                tables.fetch(:source_spends),
              strict_outputs:
                tables.fetch(:strict_outputs),
              output_clusters:
                tables.fetch(:output_clusters),
              routed_outputs:
                tables.fetch(:routed_outputs)
            )
          end

          routed_output_rows =
            table_count(
              tables.fetch(:routed_outputs)
            )

          run_stage(
            "#{prefix}_accumulate"
          ) do
            append_chunk(tables)
          end

          chunk_summaries << {
            from_height:
              window.begin,
            to_height:
              window.end,
            scan_strategy:
              SCAN_STRATEGY,
            source_input_rows:
              source_input_rows,
            all_input_rows:
              all_input_rows,
            source_transactions:
              source_transactions,
            strict_output_rows:
              strict_output_rows,
            routed_output_rows:
              routed_output_rows
          }

          drop_chunk_tables(tables)
        end

        def create_source_spends_source_first(
          table:,
          window:
        )
          connection.execute(
            source_spends_sql(
              table:
                table,
              window:
                window
            )
          )
        end

        def source_spends_sql(
          table:,
          window:
        )
          <<~SQL
            CREATE TEMP TABLE
              #{table}
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

            FROM #{source_addresses_table} source

            CROSS JOIN LATERAL (
              SELECT
                candidate.spent_txid,
                candidate.spent_block_height,
                candidate.amount_btc

              FROM cluster_inputs candidate

              WHERE candidate.address =
                    source.address

                AND candidate.spent_block_height
                  BETWEEN #{window.begin}
                      AND #{window.end}

                AND candidate.spent_txid
                    IS NOT NULL

              -- Empêche PostgreSQL d'aplatir la requête en
              -- un scan global de toute la fenêtre de blocs.
              OFFSET 0
            ) input

            GROUP BY
              input.spent_txid,
              input.spent_block_height;

            CREATE UNIQUE INDEX
              #{index_name(
                "source_first_spends_" \
                "#{current_chunk[:index]}"
              )}
            ON #{table} (
              spent_txid
            );

            ANALYZE #{table};
          SQL
        end

        def create_all_input_stats_source_first(
          source_spends:,
          all_input_stats:
        )
          connection.execute(
            all_input_stats_sql(
              source_spends:
                source_spends,
              all_input_stats:
                all_input_stats
            )
          )
        end

        def all_input_stats_sql(
          source_spends:,
          all_input_stats:
        )
          <<~SQL
            CREATE TEMP TABLE
              #{all_input_stats}
            ON COMMIT DROP
            AS

            SELECT
              spend.spent_txid,
              input_stats.all_input_rows

            FROM #{source_spends} spend

            CROSS JOIN LATERAL (
              SELECT
                COUNT(*) AS all_input_rows

              FROM cluster_inputs input

              WHERE input.spent_txid =
                    spend.spent_txid

                AND input.spent_block_height =
                    spend.spent_block_height

              -- Force un lookup indexé par transaction au lieu
              -- d'un scan global des inputs du chunk.
              OFFSET 0
            ) input_stats;

            CREATE UNIQUE INDEX
              #{index_name(
                "source_first_all_inputs_" \
                "#{current_chunk[:index]}"
              )}
            ON #{all_input_stats} (
              spent_txid
            );

            ANALYZE #{all_input_stats};
          SQL
        end

        def create_strict_outputs(
          source_spends:,
          strict_outputs:
        )
          connection.execute(
            strict_outputs_source_first_sql(
              source_spends:
                source_spends,

              strict_outputs:
                strict_outputs
            )
          )
        end

        def strict_outputs_source_first_sql(
          source_spends:,
          strict_outputs:
        )
          <<~SQL
            CREATE TEMP TABLE
              #{strict_outputs}
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

              FROM #{source_spends} spend

              CROSS JOIN LATERAL (
                SELECT
                  candidate.txid,
                  candidate.vout,
                  candidate.address,
                  candidate.amount_btc

                FROM utxo_outputs candidate

                WHERE candidate.txid =
                      spend.spent_txid

                OFFSET 0
              ) output

              UNION ALL

              SELECT
                output.txid,
                output.vout,
                output.address,
                output.amount_btc,
                0 AS source_priority

              FROM #{source_spends} spend

              CROSS JOIN LATERAL (
                SELECT
                  candidate.txid,
                  candidate.vout,
                  candidate.address,
                  candidate.amount_btc

                FROM cluster_inputs candidate

                WHERE candidate.txid =
                      spend.spent_txid

                OFFSET 0
              ) output
            ) candidate

            ORDER BY
              candidate.txid,
              candidate.vout,
              candidate.source_priority;

            CREATE INDEX
              #{index_name(
                "source_first_strict_outputs_"                 "#{current_chunk[:index]}"
              )}
            ON #{strict_outputs} (
              txid
            );

            ANALYZE #{strict_outputs};
          SQL
        end

        def summary_evidence(row)
          super.merge(
            analysis_version:
              VERSION,
            scan_strategy:
              SCAN_STRATEGY
          )
        end

        def record_empty_source_first_chunk(
          window:
        )
          chunk_summaries << {
            from_height:
              window.begin,
            to_height:
              window.end,
            scan_strategy:
              SCAN_STRATEGY,
            source_input_rows:
              0,
            all_input_rows:
              0,
            source_transactions:
              0,
            strict_output_rows:
              0,
            routed_output_rows:
              0
          }
        end

        def chunk_tables(prefix)
          {
            source_spends:
              table(
                "#{prefix}_source_spends"
              ),

            all_input_stats:
              table(
                "#{prefix}_all_input_stats"
              ),

            strict_outputs:
              table(
                "#{prefix}_strict_outputs"
              ),

            output_clusters:
              table(
                "#{prefix}_output_clusters"
              ),

            routed_outputs:
              table(
                "#{prefix}_routed_outputs"
              )
          }
        end

        def table_sum(
          table_name:,
          column_name:
        )
          quoted_column =
            connection.quote_column_name(
              column_name
            )

          connection
            .select_value(
              "SELECT COALESCE(" \
              "SUM(#{quoted_column}), 0) " \
              "FROM #{table_name}"
            )
            .to_i
        end
      end
    end
  end
end
