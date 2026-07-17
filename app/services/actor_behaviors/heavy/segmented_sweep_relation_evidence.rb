# frozen_string_literal: true

require "bigdecimal"
require "securerandom"

module ActorBehaviors
  module Heavy
    class SegmentedSweepRelationEvidence
      VERSION =
        "sweep_relation_segmented_v1"

      DEFAULT_CHUNK_SIZE =
        500

      DEFAULT_TIMEOUT_MS =
        300_000

      def self.call(
        source_cluster_id:,
        from_height:,
        to_height:,
        chunk_size: DEFAULT_CHUNK_SIZE
      )
        new(
          source_cluster_id:
            source_cluster_id,

          from_height:
            from_height,

          to_height:
            to_height,

          chunk_size:
            chunk_size
        ).call
      end

      def self.height_windows(
        from_height:,
        to_height:,
        chunk_size:
      )
        first_height =
          from_height.to_i

        last_height =
          to_height.to_i

        size =
          [
            chunk_size.to_i,
            1
          ].max

        return [] if first_height >
                     last_height

        windows = []
        cursor = first_height

        while cursor <= last_height
          chunk_end =
            [
              cursor + size - 1,
              last_height
            ].min

          windows << (
            cursor..chunk_end
          )

          cursor =
            chunk_end + 1
        end

        windows
      end

      def initialize(
        source_cluster_id:,
        from_height:,
        to_height:,
        chunk_size:
      )
        @source_cluster_id =
          source_cluster_id.to_i

        @from_height =
          from_height.to_i

        @to_height =
          to_height.to_i

        @chunk_size =
          [
            chunk_size.to_i,
            1
          ].max

        @token =
          SecureRandom.hex(6)

        @current_stage = nil
        @current_chunk = nil
        @stage_durations = {}
        @chunk_summaries = []
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

        result = nil

        connection.transaction(
          requires_new: true
        ) do
          configure_transaction

          run_stage(
            :source_addresses
          ) do
            create_source_addresses
          end

          if table_count(
            source_addresses_table
          ).zero?
            result =
              deferred(
                :source_addresses_missing
              )

            next
          end

          run_stage(
            :accumulators
          ) do
            create_accumulators
          end

          height_windows.each_with_index do |window, index|
            process_window(
              window:
                window,

              index:
                index
            )
          end

          source_transactions =
            table_count(
              all_source_spends_table
            )

          if source_transactions.zero?
            result =
              deferred(
                :no_sweep_activity
              ).merge(
                chunks:
                  chunk_summaries,

                stage_durations_seconds:
                  stage_durations
              )

            next
          end

          output_rows =
            table_count(
              all_routed_outputs_table
            )

          if output_rows.zero?
            result =
              deferred(
                :strict_outputs_missing
              ).merge(
                chunks:
                  chunk_summaries,

                stage_durations_seconds:
                  stage_durations
              )

            next
          end

          run_stage(
            :final_indexes
          ) do
            create_final_indexes
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

          if summary.nil? ||
             summary[
               "top_destination_cluster_id"
             ].blank?
            result =
              deferred(
                :external_destination_missing
              ).merge(
                chunks:
                  chunk_summaries,

                stage_durations_seconds:
                  stage_durations
              )

            next
          end

          total_duration =
            Process.clock_gettime(
              Process::CLOCK_MONOTONIC
            ) - started_at

          result = {
            ok: true,
            status: "certified",

            evidence:
              summary_evidence(
                summary
              ).merge(
                duration_seconds:
                  total_duration.round(3),

                chunk_size:
                  chunk_size,

                chunks:
                  chunk_summaries,

                stage_durations_seconds:
                  stage_durations,

                scope_counts: {
                  source_transactions:
                    source_transactions,

                  routed_output_rows:
                    output_rows
                }
              )
          }
        end

        result
      rescue ActiveRecord::QueryCanceled
        deferred(
          :statement_timeout
        ).merge(
          analysis_stage:
            current_stage,

          chunk:
            current_chunk,

          chunks:
            chunk_summaries,

          stage_durations_seconds:
            stage_durations
        )
      rescue StandardError => error
        {
          ok: false,
          status: "failed",
          reason: :calculation_failed,

          analysis_stage:
            current_stage,

          chunk:
            current_chunk,

          error_class:
            error.class.name,

          error_message:
            error.message,

          chunks:
            chunk_summaries,

          stage_durations_seconds:
            stage_durations,

          evidence: {}
        }
      end

      private

      attr_reader(
        :source_cluster_id,
        :from_height,
        :to_height,
        :chunk_size,
        :token,
        :current_stage,
        :current_chunk,
        :stage_durations,
        :chunk_summaries
      )

      def connection
        ActiveRecord::Base.connection
      end

      def height_windows
        self.class.height_windows(
          from_height:
            from_height,

          to_height:
            to_height,

          chunk_size:
            chunk_size
        )
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

      def process_window(
        window:,
        index:
      )
        @current_chunk = {
          index:
            index + 1,

          from_height:
            window.begin,

          to_height:
            window.end
        }

        prefix =
          format(
            "chunk_%02d",
            index + 1
          )

        tables =
          chunk_tables(
            prefix
          )

        run_stage(
          "#{prefix}_source_spends"
        ) do
          create_source_spends(
            table:
              tables.fetch(
                :source_spends
              ),

            window:
              window
          )
        end

        source_transactions =
          table_count(
            tables.fetch(
              :source_spends
            )
          )

        if source_transactions.zero?
          chunk_summaries << {
            from_height:
              window.begin,

            to_height:
              window.end,

            source_transactions:
              0,

            source_input_rows:
              0,

            strict_output_rows:
              0,

            routed_output_rows:
              0
          }

          drop_chunk_tables(
            tables
          )

          return
        end

        run_stage(
          "#{prefix}_strict_outputs"
        ) do
          create_strict_outputs(
            source_spends:
              tables.fetch(
                :source_spends
              ),

            strict_outputs:
              tables.fetch(
                :strict_outputs
              )
          )
        end

        strict_output_rows =
          table_count(
            tables.fetch(
              :strict_outputs
            )
          )

        run_stage(
          "#{prefix}_output_clusters"
        ) do
          create_output_clusters(
            strict_outputs:
              tables.fetch(
                :strict_outputs
              ),

            output_clusters:
              tables.fetch(
                :output_clusters
              )
          )
        end

        run_stage(
          "#{prefix}_routed_outputs"
        ) do
          create_routed_outputs(
            source_spends:
              tables.fetch(
                :source_spends
              ),

            strict_outputs:
              tables.fetch(
                :strict_outputs
              ),

            output_clusters:
              tables.fetch(
                :output_clusters
              ),

            routed_outputs:
              tables.fetch(
                :routed_outputs
              )
          )
        end

        routed_output_rows =
          table_count(
            tables.fetch(
              :routed_outputs
            )
          )

        source_input_rows =
          connection
            .select_value(
              "SELECT COALESCE(" \
              "SUM(source_input_rows), 0" \
              ") FROM " \
              "#{tables.fetch(:source_spends)}"
            )
            .to_i

        run_stage(
          "#{prefix}_accumulate"
        ) do
          append_chunk(
            tables
          )
        end

        chunk_summaries << {
          from_height:
            window.begin,

          to_height:
            window.end,

          source_transactions:
            source_transactions,

          source_input_rows:
            source_input_rows,

          strict_output_rows:
            strict_output_rows,

          routed_output_rows:
            routed_output_rows
        }

        drop_chunk_tables(
          tables
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
              #{source_cluster_id}

              AND address IS NOT NULL

              AND BTRIM(address) <> '';

            CREATE UNIQUE INDEX
              #{index_name("source_addresses")}
            ON #{source_addresses_table} (
              address
            );

            ANALYZE
              #{source_addresses_table};
          SQL
        )
      end

      def create_accumulators
        connection.execute(
          <<~SQL
            CREATE TEMP TABLE
              #{all_source_spends_table} (
                spent_txid text PRIMARY KEY,
                spent_block_height integer NOT NULL,
                source_input_rows bigint NOT NULL,
                source_input_btc numeric NOT NULL
              )
            ON COMMIT DROP;

            CREATE TEMP TABLE
              #{all_routed_outputs_table} (
                spent_txid text NOT NULL,
                spent_block_height integer NOT NULL,
                vout integer NOT NULL,
                address text,
                amount_btc numeric,
                destination_cluster_id bigint,
                route_type text NOT NULL,

                PRIMARY KEY (
                  spent_txid,
                  vout
                )
              )
            ON COMMIT DROP;
          SQL
        )
      end

      def create_source_spends(
        table:,
        window:
      )
        connection.execute(
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

            FROM cluster_inputs input

            INNER JOIN
              #{source_addresses_table}
              source

              ON source.address =
                 input.address

            WHERE input.spent_txid
              IS NOT NULL

              AND input.spent_block_height
                BETWEEN #{window.begin}
                    AND #{window.end}

            GROUP BY
              input.spent_txid,
              input.spent_block_height;

            CREATE UNIQUE INDEX
              #{index_name(
                "source_spends_#{current_chunk[:index]}"
              )}
            ON #{table} (
              spent_txid
            );

            ANALYZE #{table};
          SQL
        )
      end

      def create_strict_outputs(
        source_spends:,
        strict_outputs:
      )
        connection.execute(
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

              INNER JOIN utxo_outputs output
                ON output.txid =
                   spend.spent_txid

              UNION ALL

              SELECT
                output.txid,
                output.vout,
                output.address,
                output.amount_btc,
                0 AS source_priority

              FROM #{source_spends} spend

              INNER JOIN cluster_inputs output
                ON output.txid =
                   spend.spent_txid
            ) candidate

            ORDER BY
              candidate.txid,
              candidate.vout,
              candidate.source_priority;

            CREATE INDEX
              #{index_name(
                "strict_outputs_#{current_chunk[:index]}"
              )}
            ON #{strict_outputs} (
              txid
            );

            ANALYZE #{strict_outputs};
          SQL
        )
      end

      def create_output_clusters(
        strict_outputs:,
        output_clusters:
      )
        connection.execute(
          <<~SQL
            CREATE TEMP TABLE
              #{output_clusters}
            ON COMMIT DROP
            AS

            SELECT
              output_address.address,

              destination.cluster_id
                AS destination_cluster_id

            FROM (
              SELECT DISTINCT
                output.address

              FROM #{strict_outputs} output

              WHERE output.address IS NOT NULL

                AND BTRIM(
                  output.address
                ) <> ''
            ) output_address

            LEFT JOIN addresses destination
              ON destination.address =
                 output_address.address;

            CREATE UNIQUE INDEX
              #{index_name(
                "output_clusters_#{current_chunk[:index]}"
              )}
            ON #{output_clusters} (
              address
            );

            ANALYZE #{output_clusters};
          SQL
        )
      end

      def create_routed_outputs(
        source_spends:,
        strict_outputs:,
        output_clusters:,
        routed_outputs:
      )
        connection.execute(
          <<~SQL
            CREATE TEMP TABLE
              #{routed_outputs}
            ON COMMIT DROP
            AS

            SELECT
              spend.spent_txid,
              spend.spent_block_height,
              output.vout,
              output.address,
              output.amount_btc,

              destination
                .destination_cluster_id,

              CASE
                WHEN output.address IS NULL
                  OR BTRIM(
                    output.address
                  ) = ''
                  THEN 'non_address_output'

                WHEN destination
                       .destination_cluster_id
                     IS NULL
                  THEN 'unclustered_destination'

                WHEN destination
                       .destination_cluster_id =
                     #{source_cluster_id}
                  THEN 'same_cluster'

                ELSE 'external_cluster'
              END AS route_type

            FROM #{source_spends} spend

            INNER JOIN #{strict_outputs} output
              ON output.txid =
                 spend.spent_txid

            LEFT JOIN #{output_clusters}
              destination

              ON destination.address =
                 output.address;

            ANALYZE #{routed_outputs};
          SQL
        )
      end

      def append_chunk(tables)
        connection.execute(
          <<~SQL
            INSERT INTO
              #{all_source_spends_table} (
                spent_txid,
                spent_block_height,
                source_input_rows,
                source_input_btc
              )

            SELECT
              spent_txid,
              spent_block_height,
              source_input_rows,
              source_input_btc

            FROM
              #{tables.fetch(:source_spends)}

            ON CONFLICT (
              spent_txid
            ) DO NOTHING;

            INSERT INTO
              #{all_routed_outputs_table} (
                spent_txid,
                spent_block_height,
                vout,
                address,
                amount_btc,
                destination_cluster_id,
                route_type
              )

            SELECT
              spent_txid,
              spent_block_height,
              vout,
              address,
              amount_btc,
              destination_cluster_id,
              route_type

            FROM
              #{tables.fetch(:routed_outputs)}

            ON CONFLICT (
              spent_txid,
              vout
            ) DO NOTHING;
          SQL
        )
      end

      def create_final_indexes
        connection.execute(
          <<~SQL
            CREATE INDEX
              #{index_name("routed_destination")}
            ON #{all_routed_outputs_table} (
              destination_cluster_id
            );

            CREATE INDEX
              #{index_name("routed_txid")}
            ON #{all_routed_outputs_table} (
              spent_txid
            );

            ANALYZE
              #{all_source_spends_table};

            ANALYZE
              #{all_routed_outputs_table};
          SQL
        )
      end

      def summary_sql
        <<~SQL
          WITH source_summary AS (
            SELECT
              COUNT(*) AS
                consolidation_transactions,

              COUNT(
                DISTINCT spent_block_height
              ) AS consolidation_blocks,

              MIN(
                spent_block_height
              ) AS first_consolidation_height,

              MAX(
                spent_block_height
              ) AS last_consolidation_height,

              COALESCE(
                SUM(source_input_rows),
                0
              ) AS source_input_rows,

              COALESCE(
                SUM(source_input_btc),
                0
              ) AS source_input_btc

            FROM #{all_source_spends_table}
          ),

          output_summary AS (
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

            FROM #{all_routed_outputs_table}
          ),

          destination_totals AS (
            SELECT
              destination_cluster_id,

              COUNT(
                DISTINCT spent_txid
              ) AS transactions,

              COALESCE(
                SUM(amount_btc),
                0
              ) AS received_btc

            FROM #{all_routed_outputs_table}

            WHERE route_type =
              'external_cluster'

            GROUP BY
              destination_cluster_id
          ),

          ranked_destinations AS (
            SELECT
              destination.*,

              ROW_NUMBER() OVER (
                ORDER BY
                  received_btc DESC,
                  destination_cluster_id
              ) AS destination_rank

            FROM destination_totals
              destination
          )

          SELECT
            source_summary.*,
            output_summary.*,

            top_destination
              .destination_cluster_id
              AS top_destination_cluster_id,

            top_destination.transactions
              AS top_destination_transactions,

            top_destination.received_btc
              AS top_destination_received_btc,

            ROUND(
              (
                100.0 *
                top_destination.received_btc /

                NULLIF(
                  output_summary
                    .external_cluster_btc +
                  output_summary
                    .unclustered_btc,
                  0
                )
              )::numeric,
              2
            ) AS
              top_destination_share_percent

          FROM source_summary

          CROSS JOIN output_summary

          LEFT JOIN ranked_destinations
            top_destination

            ON top_destination.destination_rank =
               1
        SQL
      end

      def summary_evidence(row)
        {
          analysis_version:
            VERSION,

          source_cluster_id:
            source_cluster_id,

          window_from_height:
            from_height,

          window_to_height:
            to_height,

          consolidation_transactions:
            row[
              "consolidation_transactions"
            ].to_i,

          consolidation_blocks:
            row[
              "consolidation_blocks"
            ].to_i,

          first_consolidation_height:
            row[
              "first_consolidation_height"
            ]&.to_i,

          last_consolidation_height:
            row[
              "last_consolidation_height"
            ]&.to_i,

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
            row[
              "top_destination_cluster_id"
            ]&.to_i,

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
      end

      def run_stage(name)
        @current_stage =
          name.to_s

        started_at =
          Process.clock_gettime(
            Process::CLOCK_MONOTONIC
          )

        puts
        puts(
          "===== Heavy segmented sweep: " \
          "#{name} ====="
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
          "Terminé en " \
          "#{duration.round(2)} s"
        )

        result
      rescue StandardError
        duration =
          Process.clock_gettime(
            Process::CLOCK_MONOTONIC
          ) - started_at

        stage_durations[
          name.to_s
        ] =
          duration.round(3)

        raise
      end

      def chunk_tables(prefix)
        {
          source_spends:
            table(
              "#{prefix}_source_spends"
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

      def drop_chunk_tables(tables)
        connection.execute(
          "DROP TABLE IF EXISTS " \
          "#{tables.values.join(', ')}"
        )
      end

      def table_count(table_name)
        connection
          .select_value(
            "SELECT COUNT(*) " \
            "FROM #{table_name}"
          )
          .to_i
      end

      def table(suffix)
        connection.quote_table_name(
          "tmp_abh_sweep_#{token}_#{suffix}"
        )
      end

      def index_name(suffix)
        connection.quote_column_name(
          "idx_abh_sweep_#{token}_#{suffix}"
        )
      end

      def source_addresses_table
        table(
          "source_addresses"
        )
      end

      def all_source_spends_table
        table(
          "all_source_spends"
        )
      end

      def all_routed_outputs_table
        table(
          "all_routed_outputs"
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
