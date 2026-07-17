# frozen_string_literal: true

require "pp"

$stdout.sync = true
$stderr.sync = true

connection =
  ActiveRecord::Base.connection

wallet_cluster_ids =
  ENV.fetch(
    "WALLET_CLUSTER_IDS",
    "39960,51461,948792,130448"
  )
    .split(",")
    .map(&:strip)
    .reject(&:empty?)
    .map { |value| Integer(value, 10) }
    .select(&:positive?)
    .uniq
    .sort

raise(
  "Aucun wallet cluster valide"
) if wallet_cluster_ids.empty?

to_height =
  BlockBufferModel
    .where(status: "processed")
    .maximum(:height)
    .to_i

window_blocks =
  [
    ENV.fetch(
      "WINDOW_BLOCKS",
      "500"
    ).to_i,
    1
  ].max

from_height =
  [
    to_height - window_blocks + 1,
    0
  ].max

puts(
  "Fenêtre audit : "   "#{from_height}..#{to_height} "   "(#{window_blocks} blocs)"
)

puts(
  "Wallets : "   "#{wallet_cluster_ids.join(', ')}"
)

top_n =
  [
    ENV.fetch(
      "TOP_DESTINATIONS",
      "10"
    ).to_i,
    1
  ].max

values_sql =
  wallet_cluster_ids.map do |cluster_id|
    "(#{cluster_id}::bigint)"
  end.join(",")

durations = {}

run_step =
  lambda do |name, sql|
    started_at =
      Process.clock_gettime(
        Process::CLOCK_MONOTONIC
      )

    puts
    puts "===== #{name} ====="

    result =
      connection.execute(sql)

    duration =
      Process.clock_gettime(
        Process::CLOCK_MONOTONIC
      ) - started_at

    durations[name] =
      duration.round(3)

    puts(
      "Terminé en #{duration.round(2)} s"
    )

    result
  end

connection.execute(
  "SET statement_timeout = '5min'"
)

connection.execute(
  "SET lock_timeout = '2s'"
)

begin
  run_step.call(
    "1/10 Périmètre",
    <<~SQL
      CREATE TEMP TABLE
        audit_target_wallets (
          source_cluster_id bigint
            PRIMARY KEY
        )
    SQL
  )

  run_step.call(
    "2/10 Chargement des wallets",
    <<~SQL
      INSERT INTO audit_target_wallets (
        source_cluster_id
      )
      VALUES
        #{values_sql}
    SQL
  )

  run_step.call(
    "3/10 Fenêtre et transactions sortantes",
    <<~SQL
      CREATE TEMP TABLE
        audit_source_addresses AS

      SELECT
        address.address,
        address.cluster_id
          AS source_cluster_id

      FROM addresses address

      INNER JOIN audit_target_wallets target
        ON target.source_cluster_id =
           address.cluster_id

      WHERE address.address IS NOT NULL
        AND BTRIM(address.address) <> '';

      CREATE UNIQUE INDEX
        audit_source_addresses_address_idx
      ON audit_source_addresses (
        address
      );

      ANALYZE audit_source_addresses;

      CREATE TEMP TABLE
        audit_window_inputs AS

      SELECT
        input.address,
        input.txid,
        input.vout,
        input.amount_btc,
        input.block_height,
        input.spent_txid,
        input.spent_block_height

      FROM cluster_inputs input

      WHERE input.spent_block_height
        BETWEEN #{from_height}
            AND #{to_height}

        AND input.spent_txid IS NOT NULL;

      CREATE INDEX
        audit_window_inputs_address_idx
      ON audit_window_inputs (
        address
      );

      CREATE INDEX
        audit_window_inputs_spent_txid_idx
      ON audit_window_inputs (
        spent_txid
      );

      CREATE INDEX
        audit_window_inputs_height_txid_idx
      ON audit_window_inputs (
        spent_block_height,
        spent_txid
      );

      ANALYZE audit_window_inputs;

      CREATE TEMP TABLE
        audit_source_spends AS

      SELECT
        source_address.source_cluster_id,
        input.spent_txid,
        input.spent_block_height,

        COUNT(*) AS source_input_rows,

        COALESCE(
          SUM(input.amount_btc),
          0
        ) AS source_input_btc

      FROM audit_window_inputs input

      INNER JOIN audit_source_addresses
        source_address

        ON source_address.address =
           input.address

      GROUP BY
        source_address.source_cluster_id,
        input.spent_txid,
        input.spent_block_height
    SQL
  )

  run_step.call(
    "4/10 Index des transactions",
    <<~SQL
      CREATE INDEX
        audit_source_spends_txid_idx
      ON audit_source_spends (
        spent_txid
      );

      CREATE INDEX
        audit_source_spends_height_txid_idx
      ON audit_source_spends (
        spent_block_height,
        spent_txid
      );

      ANALYZE audit_source_spends;

      CREATE TEMP TABLE
        audit_spend_transactions AS

      SELECT DISTINCT
        spent_txid,
        spent_block_height

      FROM audit_source_spends;

      CREATE UNIQUE INDEX
        audit_spend_transactions_txid_idx
      ON audit_spend_transactions (
        spent_txid
      );

      CREATE INDEX
        audit_spend_transactions_height_txid_idx
      ON audit_spend_transactions (
        spent_block_height,
        spent_txid
      );

      ANALYZE audit_spend_transactions;
    SQL
  )

  run_step.call(
    "5/10 Analyse des inputs complets",
    <<~SQL
      CREATE TEMP TABLE
        audit_all_input_stats AS

      SELECT
        transaction.spent_txid,

        COUNT(*) AS all_input_rows,

        COALESCE(
          SUM(input.amount_btc),
          0
        ) AS all_input_btc,

        COUNT(
          DISTINCT input_address.cluster_id
        ) FILTER (
          WHERE input_address.cluster_id
            IS NOT NULL
        ) AS all_input_clusters_count

      FROM audit_spend_transactions transaction

      INNER JOIN audit_window_inputs input
        ON input.spent_block_height =
           transaction.spent_block_height

       AND input.spent_txid =
           transaction.spent_txid

      LEFT JOIN addresses input_address
        ON input_address.address =
           input.address

      GROUP BY transaction.spent_txid;

      CREATE UNIQUE INDEX
        audit_all_input_stats_txid_idx
      ON audit_all_input_stats (
        spent_txid
      );

      ANALYZE audit_all_input_stats;
    SQL
  )

  run_step.call(
    "6/10 Reconstruction des outputs stricts",
    <<~SQL
      CREATE TEMP TABLE
        audit_strict_outputs AS

      SELECT DISTINCT ON (
        candidate.txid,
        candidate.vout
      )
        candidate.txid,
        candidate.vout,
        candidate.address,
        candidate.amount_btc,
        candidate.block_height,
        candidate.fact_source

      FROM (
        SELECT
          output.txid,
          output.vout,
          output.address,
          output.amount_btc,
          output.block_height,
          'utxo_outputs' AS fact_source,
          1 AS source_priority

        FROM audit_spend_transactions transaction

        INNER JOIN utxo_outputs output
          ON output.txid =
             transaction.spent_txid

        UNION ALL

        SELECT
          spent_output.txid,
          spent_output.vout,
          spent_output.address,
          spent_output.amount_btc,
          spent_output.block_height,
          'cluster_inputs' AS fact_source,
          0 AS source_priority

        FROM audit_spend_transactions transaction

        INNER JOIN cluster_inputs spent_output
          ON spent_output.txid =
             transaction.spent_txid
      ) candidate

      ORDER BY
        candidate.txid,
        candidate.vout,
        candidate.source_priority
    SQL
  )

  run_step.call(
    "7/10 Index des outputs",
    <<~SQL
      CREATE INDEX
        audit_strict_outputs_txid_idx
      ON audit_strict_outputs (
        txid
      );

      ANALYZE audit_strict_outputs;
    SQL
  )

  run_step.call(
    "8/10 Routage des outputs",
    <<~SQL
      CREATE TEMP TABLE
        audit_routed_outputs AS

      SELECT
        spend.source_cluster_id,
        spend.spent_txid,
        spend.spent_block_height,

        output.vout,
        output.address,
        output.amount_btc,

        destination.cluster_id
          AS destination_cluster_id,

        CASE
          WHEN output.address IS NULL
            OR BTRIM(output.address) = ''
            THEN 'non_address_output'

          WHEN destination.cluster_id IS NULL
            THEN 'unclustered_destination'

          WHEN destination.cluster_id =
               spend.source_cluster_id
            THEN 'same_cluster'

          ELSE 'external_cluster'
        END AS route_type

      FROM audit_source_spends spend

      INNER JOIN audit_strict_outputs output
        ON output.txid =
           spend.spent_txid

      LEFT JOIN addresses destination
        ON destination.address =
           output.address;

      CREATE INDEX
        audit_routed_outputs_source_idx
      ON audit_routed_outputs (
        source_cluster_id
      );

      CREATE INDEX
        audit_routed_outputs_txid_idx
      ON audit_routed_outputs (
        spent_txid
      );

      ANALYZE audit_routed_outputs;
    SQL
  )

  run_step.call(
    "9/10 Agrégats",
    <<~SQL
      CREATE TEMP TABLE
        audit_transaction_output_stats AS

      SELECT
        source_cluster_id,
        spent_txid,
        spent_block_height,

        COUNT(*) AS output_rows,

        COUNT(*) FILTER (
          WHERE route_type IN (
            'external_cluster',
            'unclustered_destination'
          )
        ) AS external_output_rows,

        COUNT(
          DISTINCT address
        ) FILTER (
          WHERE route_type IN (
            'external_cluster',
            'unclustered_destination'
          )
        ) AS external_destination_addresses,

        COUNT(
          DISTINCT destination_cluster_id
        ) FILTER (
          WHERE route_type =
            'external_cluster'
        ) AS external_destination_clusters,

        COALESCE(
          SUM(amount_btc),
          0
        ) AS total_output_btc

      FROM audit_routed_outputs

      GROUP BY
        source_cluster_id,
        spent_txid,
        spent_block_height;

      CREATE UNIQUE INDEX
        audit_transaction_outputs_key_idx
      ON audit_transaction_output_stats (
        source_cluster_id,
        spent_txid
      );

      CREATE TEMP TABLE
        audit_transaction_metrics AS

      SELECT
        spend.source_cluster_id,
        spend.spent_txid,
        spend.spent_block_height,
        spend.source_input_rows,
        spend.source_input_btc,

        inputs.all_input_rows,
        inputs.all_input_btc,
        inputs.all_input_clusters_count,

        outputs.output_rows,
        outputs.external_output_rows,
        outputs.external_destination_addresses,
        outputs.external_destination_clusters,
        outputs.total_output_btc

      FROM audit_source_spends spend

      INNER JOIN audit_all_input_stats inputs
        ON inputs.spent_txid =
           spend.spent_txid

      LEFT JOIN audit_transaction_output_stats outputs
        ON outputs.source_cluster_id =
           spend.source_cluster_id

       AND outputs.spent_txid =
           spend.spent_txid;

      CREATE TEMP TABLE
        audit_source_route_totals AS

      SELECT
        source_cluster_id,

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
        ) AS unclustered_btc,

        COALESCE(
          SUM(amount_btc)
            FILTER (
              WHERE route_type =
                'non_address_output'
            ),
          0
        ) AS non_address_btc

      FROM audit_routed_outputs

      GROUP BY source_cluster_id;

      CREATE TEMP TABLE
        audit_destination_totals AS

      SELECT
        source_cluster_id,
        destination_cluster_id,

        COUNT(
          DISTINCT spent_txid
        ) AS transactions,

        COUNT(*) AS output_rows,

        COUNT(
          DISTINCT address
        ) AS destination_addresses,

        COALESCE(
          SUM(amount_btc),
          0
        ) AS received_btc,

        MIN(
          spent_block_height
        ) AS first_height,

        MAX(
          spent_block_height
        ) AS last_height

      FROM audit_routed_outputs

      WHERE route_type =
        'external_cluster'

      GROUP BY
        source_cluster_id,
        destination_cluster_id;

      CREATE TEMP TABLE
        audit_ranked_destinations AS

      SELECT
        destination.*,

        SUM(
          received_btc
        ) OVER (
          PARTITION BY source_cluster_id
        ) AS source_clustered_external_btc,

        ROW_NUMBER() OVER (
          PARTITION BY source_cluster_id

          ORDER BY
            received_btc DESC,
            transactions DESC,
            destination_cluster_id
        ) AS destination_rank

      FROM audit_destination_totals destination;

      ANALYZE audit_transaction_metrics;
      ANALYZE audit_source_route_totals;
      ANALYZE audit_ranked_destinations;
    SQL
  )

  started_at =
    Process.clock_gettime(
      Process::CLOCK_MONOTONIC
    )

  puts
  puts "===== 10/10 Résultats ====="

  summaries =
    connection.exec_query(
      <<~SQL
        SELECT
          metrics.source_cluster_id,

          COUNT(*) AS spending_transactions,

          COUNT(
            DISTINCT metrics.spent_block_height
          ) AS spending_blocks,

          MIN(
            metrics.spent_block_height
          ) AS first_spent_height,

          MAX(
            metrics.spent_block_height
          ) AS last_spent_height,

          COALESCE(
            SUM(metrics.source_input_btc),
            0
          ) AS source_input_btc,

          COUNT(*) FILTER (
            WHERE
              metrics.all_input_clusters_count > 1
          ) AS mixed_input_transactions,

          COUNT(*) FILTER (
            WHERE metrics.output_rows IS NULL
          ) AS missing_output_transactions,

          ROUND(
            AVG(
              COALESCE(
                metrics.output_rows,
                0
              )
            )::numeric,
            2
          ) AS average_outputs_per_transaction,

          ROUND(
            PERCENTILE_CONT(0.5)
              WITHIN GROUP (
                ORDER BY COALESCE(
                  metrics.output_rows,
                  0
                )
              )::numeric,
            2
          ) AS median_outputs_per_transaction,

          ROUND(
            PERCENTILE_CONT(0.9)
              WITHIN GROUP (
                ORDER BY COALESCE(
                  metrics.output_rows,
                  0
                )
              )::numeric,
            2
          ) AS p90_outputs_per_transaction,

          COUNT(*) FILTER (
            WHERE COALESCE(
              metrics.output_rows,
              0
            ) >= 5
          ) AS batch_transactions,

          ROUND(
            (
              100.0 *
              COUNT(*) FILTER (
                WHERE COALESCE(
                  metrics.output_rows,
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

          route.distinct_external_addresses,
          route.distinct_external_clusters,
          route.same_cluster_btc,
          route.external_cluster_btc,
          route.unclustered_btc,
          route.non_address_btc,

          route.external_cluster_btc +
          route.unclustered_btc
            AS total_external_btc,

          ROUND(
            (
              100.0 *
              route.unclustered_btc /
              NULLIF(
                route.external_cluster_btc +
                route.unclustered_btc,
                0
              )
            )::numeric,
            2
          ) AS unclustered_external_percent,

          top_destination.destination_cluster_id
            AS top_destination_cluster_id,

          top_destination.received_btc
            AS top_destination_btc,

          ROUND(
            (
              100.0 *
              top_destination.received_btc /
              NULLIF(
                route.external_cluster_btc +
                route.unclustered_btc,
                0
              )
            )::numeric,
            2
          ) AS top_destination_share_percent

        FROM audit_transaction_metrics metrics

        INNER JOIN audit_source_route_totals route
          ON route.source_cluster_id =
             metrics.source_cluster_id

        LEFT JOIN audit_ranked_destinations
          top_destination

          ON top_destination.source_cluster_id =
             metrics.source_cluster_id

         AND top_destination.destination_rank = 1

        GROUP BY
          metrics.source_cluster_id,
          route.distinct_external_addresses,
          route.distinct_external_clusters,
          route.same_cluster_btc,
          route.external_cluster_btc,
          route.unclustered_btc,
          route.non_address_btc,
          top_destination.destination_cluster_id,
          top_destination.received_btc

        ORDER BY metrics.source_cluster_id
      SQL
    ).to_a

  top_destinations =
    connection.exec_query(
      <<~SQL
        SELECT
          source_cluster_id,
          destination_rank,
          destination_cluster_id,
          transactions,
          output_rows,
          destination_addresses,
          received_btc,
          first_height,
          last_height,

          ROUND(
            (
              100.0 *
              received_btc /
              NULLIF(
                source_clustered_external_btc,
                0
              )
            )::numeric,
            2
          ) AS share_of_clustered_external_percent

        FROM audit_ranked_destinations

        WHERE destination_rank <=
          #{top_n.to_i}

        ORDER BY
          source_cluster_id,
          destination_rank
      SQL
    ).to_a

  duration =
    Process.clock_gettime(
      Process::CLOCK_MONOTONIC
    ) - started_at

  durations["10/10 Résultats"] =
    duration.round(3)

  analysis =
    summaries.map do |row|
      spending_transactions =
        row[
          "spending_transactions"
        ].to_i

      external_addresses =
        row[
          "distinct_external_addresses"
        ].to_i

      external_clusters =
        row[
          "distinct_external_clusters"
        ].to_i

      batch_percent =
        row[
          "batch_transaction_percent"
        ].to_d

      top_share =
        row[
          "top_destination_share_percent"
        ].to_d

      missing_outputs =
        row[
          "missing_output_transactions"
        ].to_i

      pattern =
        if missing_outputs.positive?
          "incomplete_output_facts"

        elsif spending_transactions >= 20 &&
              external_addresses >= 100 &&
              batch_percent >= 20 &&
              top_share < 80
          "broad_batch_distribution"

        elsif spending_transactions >= 20 &&
              external_addresses >= 50 &&
              external_clusters >= 10 &&
              top_share < 90
          "active_distribution"

        elsif top_share >= 80
          "concentrated_routing"

        elsif spending_transactions < 10
          "insufficient_history"

        else
          "mixed_distribution"
        end

      {
        source_cluster_id:
          row[
            "source_cluster_id"
          ].to_i,

        spending_transactions:
          spending_transactions,

        spending_blocks:
          row[
            "spending_blocks"
          ].to_i,

        mixed_input_transactions:
          row[
            "mixed_input_transactions"
          ].to_i,

        missing_output_transactions:
          missing_outputs,

        average_outputs_per_transaction:
          row[
            "average_outputs_per_transaction"
          ].to_d,

        median_outputs_per_transaction:
          row[
            "median_outputs_per_transaction"
          ].to_d,

        p90_outputs_per_transaction:
          row[
            "p90_outputs_per_transaction"
          ].to_d,

        batch_transactions:
          row[
            "batch_transactions"
          ].to_i,

        batch_transaction_percent:
          batch_percent,

        distinct_external_addresses:
          external_addresses,

        distinct_external_clusters:
          external_clusters,

        total_external_btc:
          row[
            "total_external_btc"
          ].to_d,

        unclustered_external_percent:
          row[
            "unclustered_external_percent"
          ].to_d,

        top_destination_cluster_id:
          row[
            "top_destination_cluster_id"
          ]&.to_i,

        top_destination_share_percent:
          top_share,

        preliminary_pattern:
          pattern
      }
    end

  pp({
    mode:
      "read_only_downstream_wallet_distribution_v2",

    wallet_cluster_ids:
      wallet_cluster_ids,

    current_layer1_height:
      BlockBufferModel
        .where(status: "processed")
        .maximum(:height),

    temporary_counts: {
      source_addresses:
        connection.select_value(
          "SELECT COUNT(*) " \
          "FROM audit_source_addresses"
        ).to_i,

      window_inputs:
        connection.select_value(
          "SELECT COUNT(*) " \
          "FROM audit_window_inputs"
        ).to_i,

      source_transactions:
        connection.select_value(
          "SELECT COUNT(*) " \
          "FROM audit_source_spends"
        ).to_i,

      strict_outputs:
        connection.select_value(
          "SELECT COUNT(*) " \
          "FROM audit_strict_outputs"
        ).to_i,

      routed_outputs:
        connection.select_value(
          "SELECT COUNT(*) " \
          "FROM audit_routed_outputs"
        ).to_i
    },

    stage_durations_seconds:
      durations,

    summaries:
      summaries,

    top_destinations:
      top_destinations,

    preliminary_analysis:
      analysis
  })
ensure
  connection.execute(
    <<~SQL
      DROP TABLE IF EXISTS
        audit_ranked_destinations,
        audit_destination_totals,
        audit_source_route_totals,
        audit_transaction_metrics,
        audit_transaction_output_stats,
        audit_routed_outputs,
        audit_strict_outputs,
        audit_all_input_stats,
        audit_spend_transactions,
        audit_source_spends,
        audit_window_inputs,
        audit_source_addresses,
        audit_target_wallets
    SQL
  )
end
