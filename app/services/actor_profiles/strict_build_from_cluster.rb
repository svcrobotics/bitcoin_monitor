# frozen_string_literal: true

module ActorProfiles
class StrictBuildFromCluster
SOURCE = "actor_profiles_strict_build_from_cluster"
PROFILE_VERSION = "strict_v5_address_spend_projection"
NEXT_PROFILE_VERSION =
  "strict_v6_cluster_transaction_projection"

NEXT_PROFILE_PROVENANCE = %w[
  addresses
  address_spend_stats
  cluster_transaction_projection
  utxo_outputs
].freeze

PROFILE_STATEMENT_TIMEOUT_SECONDS =
  [
    Integer(
      ENV.fetch(
        "ACTOR_PROFILE_STRICT_PROFILE_TIMEOUT_SECONDS",
        "120"
      )
    ),
    1
  ].max

TRANSACTION_COUNTS_TIMEOUT_SECONDS =
  [
    [
      Integer(
        ENV.fetch(
          "ACTOR_PROFILE_STRICT_TRANSACTION_COUNTS_TIMEOUT_SECONDS",
          "10"
        )
      ),
      1
    ].max,
    PROFILE_STATEMENT_TIMEOUT_SECONDS
  ].min

SATOSHI = BigDecimal("100000000")

# Espace de verrou PostgreSQL réservé à ActorProfile.
# Le verrou est transactionnel et automatiquement libéré
# à la fin de la transaction.
ADVISORY_LOCK_NAMESPACE = 41_021

BTC_COLUMNS =
  %w[
    amount_btc
    value_btc
    btc
    amount
    value
  ].freeze

SAT_COLUMNS =
  %w[
    amount_sats
    value_sats
    sats
    satoshis
  ].freeze

def self.call(cluster_id:)
  new(cluster_id: cluster_id).call
end

def initialize(cluster_id:)
  @cluster_id = cluster_id.to_i
  @stage_timings = {}
end

def call
  started_at =
    Process.clock_gettime(
      Process::CLOCK_MONOTONIC
    )

  ActiveRecord::Base.transaction(
    isolation: :repeatable_read
  ) do
    ActiveRecord::Base.connection.execute(
      "SET LOCAL statement_timeout = #{PROFILE_STATEMENT_TIMEOUT_SECONDS * 1000}"
    )

    unless acquire_cluster_build_lock
      raise ActorProfiles::DeferredSnapshotError.new(
        "ActorProfile build already running " \
        "cluster_id=#{@cluster_id}",
        cluster_id: @cluster_id,
        reason: "cluster_build_locked",
        details: {
          advisory_lock_namespace:
            ADVISORY_LOCK_NAMESPACE
        }
      )
    end

    cluster =
      Cluster
      .lock
      .find(@cluster_id)

      cluster_composition_version =
      cluster.composition_version.to_i

    cluster_tip = current_cluster_tip
    layer1_tip = current_layer1_tip

    raise "Cluster strict tip missing" if cluster_tip.zero?
    raise "Layer1 processed tip missing" if layer1_tip.zero?

    epoch =
      ActorProfiles::
        CertificationEpoch::
        current

    unless epoch
      raise ActorProfiles::DeferredSnapshotError.new(
        "ActorProfile certification epoch is inactive",
        cluster_id: cluster.id,
        reason: "certification_epoch_inactive",
        details: {
          cluster_tip: cluster_tip
        }
      )
    end

    if cluster_tip > layer1_tip
      raise ActorProfiles::DeferredSnapshotError.new(
        "Cluster strict tip is ahead of Layer1 " \
        "cluster_tip=#{cluster_tip} " \
        "layer1_tip=#{layer1_tip}",
        cluster_id: cluster.id,
        reason: "cluster_tip_ahead_of_layer1",
        details: {
          cluster_tip: cluster_tip,
          layer1_tip: layer1_tip,
          cluster_composition_version: cluster_composition_version
        }
      )
    end

    if cluster.last_seen_height.to_i <
       epoch.start_height.to_i
      raise ActorProfiles::DeferredSnapshotError.new(
        "Cluster predates ActorProfile certification epoch "         "cluster_id=#{cluster.id} "         "cluster_last_seen_height=#{cluster.last_seen_height} "         "epoch_start_height=#{epoch.start_height}",
        cluster_id: cluster.id,
        reason: "cluster_before_certification_epoch",
        details: {
          cluster_last_seen_height:
            cluster.last_seen_height.to_i,
          certification_epoch_height:
            epoch.start_height.to_i
        }
      )
    end

    if cluster.last_seen_height.to_i > cluster_tip
      raise ActorProfiles::DeferredSnapshotError.new(
        "Cluster is ahead of strict tip " \
        "cluster_id=#{cluster.id} " \
        "cluster_last_seen_height=#{cluster.last_seen_height} " \
        "cluster_tip=#{cluster_tip}",
        cluster_id: cluster.id,
        reason: "cluster_ahead_of_strict_tip",
        details: {
          cluster_last_seen_height:
            cluster.last_seen_height.to_i,
          cluster_tip: cluster_tip
        }
      )
    end

    stats =
      compute_source_stats(
        cluster,
        required_height:
          cluster_tip
      )

    profile_source_height =
      stats[:last_seen_height].to_i

    if profile_source_height > cluster_tip
      raise ActorProfiles::DeferredSnapshotError.new(
        "ActorProfile source is ahead of strict snapshot " \
        "cluster_id=#{cluster.id} " \
        "profile_source_height=#{profile_source_height} " \
        "cluster_tip=#{cluster_tip}",
        cluster_id: cluster.id,
        reason: "profile_source_ahead_of_strict_tip",
        details: {
          profile_source_height:
            profile_source_height,
          cluster_tip:
            cluster_tip
        }
      )
    end

    scores = compute_scores(stats)

    certified_at =
      Time.current

    profile =
      ActorProfile.find_or_initialize_by(
        cluster_id: cluster.id
      )

    profile.assign_attributes(
      balance_btc:
        stats[:balance_btc],

      total_received_btc:
        stats[:total_received_btc],

      total_sent_btc:
        stats[:total_sent_btc],

      net_btc:
        stats[:net_btc],

      tx_count:
        stats[:tx_count],

      inflow_count:
        stats[:inflow_count],

      outflow_count:
        stats[:outflow_count],

      first_seen_at:
        stats[:first_seen_at],

      last_seen_at:
        stats[:last_seen_at],

      # Hauteur du snapshot strict utilisé
      # pour toutes les métriques.
      last_computed_height:
        cluster_tip,
      cluster_composition_version:
        cluster_composition_version,

      dirty:
        false,

      certification_epoch_height:
        epoch.start_height,

      certification_scope:
        ActorProfile::
          CERTIFICATION_SCOPE_ACTIVITY_SINCE_EPOCH,

      certified_at:
        certified_at,

      priority:
        scores[:priority],

      accumulation_score:
        scores[:accumulation_score],

      distribution_score:
        scores[:distribution_score],

      exchange_score:
        scores[:exchange_score],

      whale_score:
        scores[:whale_score],

      etf_score:
        scores[:etf_score],

      service_score:
        scores[:service_score],

      classification:
        nil,

      traits: {
        profile_version:
          PROFILE_VERSION,

        address_count:
          stats[:address_count],

        spent_inputs_count:
          stats[:spent_inputs_count],

        spent_tx_count:
          stats[:spent_tx_count],

        live_utxo_count:
          stats[:live_utxo_count],

        first_seen_height:
          stats[:first_seen_height],

        last_seen_height:
          stats[:last_seen_height],

        activity_span_blocks:
          stats[:activity_span_blocks],

        tx_density:
          stats[:tx_density].to_s("F"),

        balance_btc:
          stats[:balance_btc].to_s("F"),

        total_sent_btc:
          stats[:total_sent_btc].to_s("F"),

        gross_received_btc:
          stats[:gross_received_btc].to_s("F"),

        gross_spent_input_btc:
          stats[:gross_spent_input_btc].to_s("F"),

        received_outputs_count:
          stats[:received_outputs_count],

        received_tx_count:
          stats[:received_tx_count],

        spending_tx_count:
          stats[:spending_tx_count],

        activity_tx_count:
          stats[:activity_tx_count]
      },

      metadata: {
        source:
          SOURCE,

        profile_version:
          PROFILE_VERSION,

        strict:
          true,

        certification_epoch_height:
          epoch.start_height,

        certification_scope:
          ActorProfile::
            CERTIFICATION_SCOPE_ACTIVITY_SINCE_EPOCH,

        certified_at:
          certified_at,

        computed_at:
          Time.current,

        runtime_ms:
          elapsed_ms(started_at),

        stats_source:
          "addresses_address_spend_stats_" \
          "cluster_inputs_utxo_outputs",

        address_spend_projection_version:
          AddressSpendStats::
            ProjectBlock::
            PROJECTION_VERSION,

        address_spend_projection_height:
          cluster_tip,

        historical_enrichment_status:
          "missing",

        historical_enrichment_source:
          "layer1_tx_output_projection_blocks_projected_future",

        snapshot_isolation:
          "repeatable_read",

        cluster_id:
          cluster.id,

        cluster_last_seen_height:
          cluster.last_seen_height,

        cluster_tip:
          cluster_tip,

        layer1_tip:
          layer1_tip,

        layer1_cluster_lag:
          layer1_tip - cluster_tip,

        profile_source_height:
          profile_source_height,

        profile_snapshot_height:
          cluster_tip,

        freshness_basis:
          "cluster_last_seen_height_and_composition_version",

        advisory_lock_namespace:
          ADVISORY_LOCK_NAMESPACE,

        stage_timings_ms:
          @stage_timings
      }
    )

    profile.save!

    {
      ok: true,

      profile_id:
        profile.id,

      cluster_id:
        cluster.id,

      cluster_composition_version:
        profile.cluster_composition_version,

      address_count:
        stats[:address_count],

      balance_btc:
        stats[:balance_btc],

      total_received_btc:
        stats[:total_received_btc],

      total_sent_btc:
        stats[:total_sent_btc],

      tx_count:
        stats[:tx_count],

      live_utxo_count:
        stats[:live_utxo_count],

      cluster_tip:
        cluster_tip,

      layer1_tip:
        layer1_tip,

      cluster_last_seen_height:
        cluster.last_seen_height,

      profile_source_height:
        profile_source_height,

      profile_snapshot_height:
        cluster_tip,

      last_computed_height:
        profile.last_computed_height,

      runtime_ms:
        elapsed_ms(started_at),

      stage_timings_ms:
        @stage_timings
    }
  end
end

private

def acquire_cluster_build_lock
  value =
    ActiveRecord::Base
      .connection
      .select_value(
        "SELECT pg_try_advisory_xact_lock(" \
        "#{ADVISORY_LOCK_NAMESPACE}, " \
        "#{@cluster_id})"
      )

  value == true || value.to_s == "t"
end

def compute_source_stats(
  cluster,
  required_height:
)
  address_scope =
    Address.where(
      cluster_id: cluster.id
    )

  address_row =
    with_profile_stage(
      "addresses_aggregate"
    ) do
      address_scope
        .select(
          "COUNT(*) AS address_count",
          "MIN(first_seen_height) AS first_seen_height",
          "MAX(last_seen_height) AS last_seen_height",
          "MIN(created_at) AS first_seen_at",
          "MAX(updated_at) AS last_seen_at"
        )
        .take
    end

  address_count =
    address_row.address_count.to_i

  if address_count.zero?
    raise(
      "Cluster has no addresses " \
      "cluster_id=#{cluster.id}"
    )
  end

  spend_aggregate =
    begin
      with_profile_stage(
        "address_spend_cluster_aggregate"
      ) do
        AddressSpendStats::
          ClusterAggregate.call(
            cluster_id:
              cluster.id,

            required_height:
              required_height
          )
      end
    rescue AddressSpendStats::
             ClusterAggregate::
             ProjectionNotReady => error
      raise(
        ActorProfiles::
          DeferredSnapshotError.new(
            "ActorProfile waits for " \
            "AddressSpend projection " \
            "cluster_id=#{cluster.id} " \
            "required_height=" \
            "#{error.required_height} " \
            "projection_tip=" \
            "#{error.projection_tip} " \
            "next_record_height=" \
            "#{error.next_record_height}",

            cluster_id:
              cluster.id,

            reason:
              "address_spend_projection_not_ready",

            details: {
              required_height:
                error.required_height,

              projection_tip:
                error.projection_tip,

              next_record_height:
                error.next_record_height
            }
          )
      )
    end

  address_subquery =
    address_scope.select(:address)

  utxos =
    UtxoOutput.where(
      address: address_subquery
    )

  total_sent_btc =
    spend_aggregate[
      :total_sent_btc
    ]

  balance_btc =
    with_profile_stage(
      "utxo_outputs_sum"
    ) do
      sum_utxo_btc_for_cluster(
        cluster.id
      )
    end

  cluster_inputs_min_height =
    spend_aggregate[
      :first_spent_height
    ]

  utxo_outputs_min_height =
    with_profile_stage(
      "utxo_outputs_min_height"
    ) do
      min_height(utxos)
    end

  cluster_inputs_max_height =
    spend_aggregate[
      :last_spent_height
    ]

  utxo_outputs_max_height =
    with_profile_stage(
      "utxo_outputs_max_height"
    ) do
      max_height(utxos)
    end

  first_seen_height = [
    cluster.first_seen_height,
    cluster_inputs_min_height,
    utxo_outputs_min_height
  ]
    .compact
    .map(&:to_i)
    .reject(&:zero?)
    .min

  last_seen_height = [
    cluster.last_seen_height,
    cluster_inputs_max_height,
    utxo_outputs_max_height
  ]
    .compact
    .map(&:to_i)
    .reject(&:zero?)
    .max

  first_seen_height ||= 0
  last_seen_height ||= 0

  activity_span_blocks = [
    last_seen_height - first_seen_height,
    0
  ].max

  transaction_counts =
    with_profile_stage(
      "transaction_counts",
      statement_timeout_seconds:
        TRANSACTION_COUNTS_TIMEOUT_SECONDS
    ) do
      compute_transaction_counts(
        cluster.id,
        checkpoint_height:
          current_cluster_tip
      )
    end

  received_tx_count =
    transaction_counts[:received_tx_count]

  spending_tx_count =
    transaction_counts[:spending_tx_count]

  tx_count =
    transaction_counts[:activity_tx_count]

  tx_density =
    if activity_span_blocks.positive?
      (
        BigDecimal(tx_count.to_s) /
        BigDecimal(activity_span_blocks.to_s)
      ).round(4)
    else
      BigDecimal("0")
    end

  spent_inputs_count =
    spend_aggregate[
      :spent_inputs_count
    ]

  live_utxo_count =
    with_profile_stage(
      "utxo_outputs_count"
    ) do
      utxos.count
    end

  received_outputs_count =
    spent_inputs_count + live_utxo_count

  gross_received_btc =
    balance_btc + total_sent_btc

  {
    address_count:
      address_count,

    total_received_btc:
      gross_received_btc,

    total_sent_btc:
      total_sent_btc,

    balance_btc:
      balance_btc,

    net_btc:
      balance_btc,

    tx_count:
      tx_count,

    spent_tx_count:
      spending_tx_count,

    inflow_count:
      received_tx_count,

    outflow_count:
      spending_tx_count,

    received_outputs_count:
      received_outputs_count,

    received_tx_count:
      received_tx_count,

    spending_tx_count:
      spending_tx_count,

    activity_tx_count:
      tx_count,

    gross_received_btc:
      gross_received_btc,

    gross_spent_input_btc:
      total_sent_btc,

    spent_inputs_count:
      spent_inputs_count,

    live_utxo_count:
      live_utxo_count,

    first_seen_height:
      first_seen_height,

    last_seen_height:
      last_seen_height,

    activity_span_blocks:
      activity_span_blocks,

    tx_density:
      tx_density,

    first_seen_at:
      address_row.first_seen_at,

    last_seen_at:
      address_row.last_seen_at
  }
end

def with_profile_stage(
  stage,
  statement_timeout_seconds:
    PROFILE_STATEMENT_TIMEOUT_SECONDS
)
  started_at =
    Process.clock_gettime(
      Process::CLOCK_MONOTONIC
    )

  apply_stage_statement_timeout(
    statement_timeout_seconds
  )

  yield.tap do
    @stage_timings[stage] =
      elapsed_ms(started_at)
  end
rescue ActiveRecord::QueryCanceled => error
  runtime_ms =
    elapsed_ms(started_at)

  @stage_timings[stage] =
    runtime_ms

  raise ActorProfiles::DeferredSnapshotError.new(
    "ActorProfile stage timed out " \
    "cluster_id=#{@cluster_id} " \
    "stage=#{stage} " \
    "runtime_ms=#{runtime_ms}",
    cluster_id: @cluster_id,
    reason: "profile_timeout",
    details: {
      stage:
        stage,

      timeout_seconds:
        statement_timeout_seconds.to_i,

      runtime_ms:
        runtime_ms,

      error_class:
        error.class.name,

      message:
        error.message,

      stage_timings_ms:
        @stage_timings
    }
  )
ensure
  restore_profile_statement_timeout
end

def apply_stage_statement_timeout(seconds)
  timeout_seconds =
    [
      seconds.to_i,
      1
    ].max

  ActiveRecord::Base
    .connection
    .execute(
      "SET LOCAL statement_timeout = " \
      "#{timeout_seconds * 1000}"
    )
end

def restore_profile_statement_timeout
  ActiveRecord::Base
    .connection
    .execute(
      "SET LOCAL statement_timeout = " \
      "#{PROFILE_STATEMENT_TIMEOUT_SECONDS * 1000}"
    )
rescue ActiveRecord::StatementInvalid,
       ActiveRecord::QueryCanceled
  nil
end

def sum_utxo_btc_for_cluster(cluster_id)
  klass =
    UtxoOutput

  connection =
    ActiveRecord::Base.connection

  amount_column =
    amount_btc_column(klass)

  divisor =
    BigDecimal("1")

  unless amount_column
    amount_column =
      amount_sat_column(klass)

    divisor =
      SATOSHI
  end

  unless amount_column
    raise(
      "No amount column found for " \
      "#{klass.table_name}"
    )
  end

  addresses_table =
    connection.quote_table_name(
      Address.table_name
    )

  utxo_outputs_table =
    connection.quote_table_name(
      klass.table_name
    )

  quoted_amount_column =
    connection.quote_column_name(
      amount_column
    )

  quoted_cluster_id =
    connection.quote(
      cluster_id.to_i
    )

  sql = <<~SQL
    SELECT
      COALESCE(
        SUM(
          per_address.amount_total
        ),
        0
      )

    FROM #{addresses_table} addresses

    CROSS JOIN LATERAL (
      SELECT
        COALESCE(
          SUM(
            utxo_outputs.#{quoted_amount_column}
          ),
          0
        ) AS amount_total

      FROM #{utxo_outputs_table}
        utxo_outputs

      WHERE utxo_outputs.address =
            addresses.address
    ) per_address

    WHERE addresses.cluster_id =
          #{quoted_cluster_id}
  SQL

  BigDecimal(
    connection
      .select_value(sql)
      .to_s
  ) / divisor
rescue ActiveRecord::QueryCanceled
  raise
rescue StandardError => error
  raise ActorProfiles::DeferredSnapshotError.new(
    "ActorProfile UTXO calculation failed " \
    "cluster_id=#{cluster_id}",
    cluster_id: cluster_id,
    reason: "utxo_calculation_failed",
    details: {
      table:
        klass.table_name,

      error_class:
        error.class.name,

      message:
        error.message
    }
  )
end

def sum_btc(relation)
  klass = relation.klass

  if (column = amount_btc_column(klass))
    BigDecimal(
      relation.sum(column).to_s
    )
  elsif (column = amount_sat_column(klass))
    BigDecimal(
      relation.sum(column).to_s
    ) / SATOSHI
  else
    raise(
      "No amount column found for " \
      "#{klass.table_name}"
    )
  end
rescue ActiveRecord::QueryCanceled
  raise
rescue StandardError => error
  raise ActorProfiles::DeferredSnapshotError.new(
    "ActorProfile amount calculation failed " \
    "cluster_id=#{@cluster_id} " \
    "table=#{klass.table_name}",
    cluster_id: @cluster_id,
    reason: "amount_calculation_failed",
    details: {
      table:
        klass.table_name,

      error_class:
        error.class.name,

      message:
        error.message
    }
  )
end

def amount_btc_column(klass)
  BTC_COLUMNS.find do |column|
    klass.column_names.include?(column)
  end
end

def amount_sat_column(klass)
  SAT_COLUMNS.find do |column|
    klass.column_names.include?(column)
  end
end

def min_height(relation)
  column =
    height_column(relation.klass)

  column ?
    relation.minimum(column) :
    nil
end

def max_height(relation)
  column =
    height_column(relation.klass)

  column ?
    relation.maximum(column) :
    nil
end

def height_column(klass)
  %w[
    block_height
    spent_block_height
    height
  ].find do |column|
    klass.column_names.include?(column)
  end
end

def compute_transaction_counts(
  cluster_id,
  checkpoint_height:
)
  connection =
    ActiveRecord::Base.connection

  addresses_table =
    connection.quote_table_name(
      Address.table_name
    )

  cluster_inputs_table =
    connection.quote_table_name(
      ClusterInput.table_name
    )

  utxo_outputs_table =
    connection.quote_table_name(
      UtxoOutput.table_name
    )

  sql = <<~SQL
    WITH cluster_addresses AS (
      SELECT DISTINCT address

      FROM #{addresses_table}

      WHERE cluster_id = #{cluster_id.to_i}
        AND address IS NOT NULL
    ),

    received_txids AS (
      SELECT cluster_inputs.txid AS txid

      FROM #{cluster_inputs_table} cluster_inputs

      INNER JOIN cluster_addresses
        ON cluster_addresses.address =
           cluster_inputs.address

      WHERE cluster_inputs.txid IS NOT NULL
        AND cluster_inputs.block_height <=
            #{checkpoint_height.to_i}

      UNION

      SELECT utxo_outputs.txid AS txid

      FROM #{utxo_outputs_table} utxo_outputs

      INNER JOIN cluster_addresses
        ON cluster_addresses.address =
           utxo_outputs.address

      WHERE utxo_outputs.txid IS NOT NULL
        AND utxo_outputs.block_height <=
            #{checkpoint_height.to_i}
    ),

    spending_txids AS (
      SELECT DISTINCT
        cluster_inputs.spent_txid AS txid

      FROM #{cluster_inputs_table} cluster_inputs

      INNER JOIN cluster_addresses
        ON cluster_addresses.address =
           cluster_inputs.address

      WHERE cluster_inputs.spent_txid IS NOT NULL
        AND cluster_inputs.spent_block_height <=
            #{checkpoint_height.to_i}
    ),

    activity_txids AS (
      SELECT txid
      FROM received_txids

      UNION

      SELECT txid
      FROM spending_txids
    )

    SELECT
      (
        SELECT COUNT(*)
        FROM received_txids
      ) AS received_tx_count,

      (
        SELECT COUNT(*)
        FROM spending_txids
      ) AS spending_tx_count,

      (
        SELECT COUNT(*)
        FROM activity_txids
      ) AS activity_tx_count
  SQL

  row =
    connection.select_one(sql) || {}

  {
    received_tx_count:
      row["received_tx_count"].to_i,

    spending_tx_count:
      row["spending_tx_count"].to_i,

    activity_tx_count:
      row["activity_tx_count"].to_i
  }
end

def compute_scores(stats)
  address_count =
    stats[:address_count].to_i

  tx_count =
    stats[:tx_count].to_i

  balance_btc =
    stats[:balance_btc].abs

  total_received_btc =
    stats[:total_received_btc]

  total_sent_btc =
    stats[:total_sent_btc]

  whale_score =
    if balance_btc >= 10_000
      100
    elsif balance_btc >= 1_000
      85
    elsif balance_btc >= 100
      65
    elsif balance_btc >= 10
      35
    else
      5
    end

  exchange_score = [
    score_by_threshold(
      address_count,
      [
        [50_000, 100],
        [10_000, 90],
        [1_000, 70],
        [100, 40],
        [10, 15]
      ]
    ),

    score_by_threshold(
      tx_count,
      [
        [500_000, 100],
        [100_000, 90],
        [10_000, 70],
        [1_000, 45],
        [100, 20]
      ]
    )
  ].max

  service_score = [
    score_by_threshold(
      address_count,
      [
        [10_000, 85],
        [1_000, 70],
        [100, 45],
        [10, 20]
      ]
    ),

    score_by_threshold(
      tx_count,
      [
        [100_000, 85],
        [10_000, 70],
        [1_000, 45],
        [100, 20]
      ]
    )
  ].max

  etf_score =
    nil

  accumulation_score =
    nil

  distribution_score =
    nil

  max_score = [
    whale_score,
    exchange_score,
    service_score
  ].compact.max.to_i

  {
    priority:
      if max_score >= 80
        "high"
      elsif max_score >= 50
        "medium"
      else
        "low"
      end,

    whale_score:
      whale_score,

    exchange_score:
      exchange_score,

    service_score:
      service_score,

    etf_score:
      etf_score,

    accumulation_score:
      accumulation_score,

    distribution_score:
      distribution_score
  }
end

def score_by_threshold(value, thresholds)
  numeric =
    BigDecimal(value.to_s)

  thresholds.each do |threshold, score|
    return score if numeric >=
                    BigDecimal(threshold.to_s)
  end

  0
end

def current_layer1_tip
  @current_layer1_tip ||=
    if defined?(BlockBufferModel)
      BlockBufferModel
        .where(status: "processed")
        .maximum(:height)
        .to_i
    else
      0
    end
end

def current_cluster_tip
  @current_cluster_tip ||=
    if defined?(ClusterProcessedBlock)
      ClusterProcessedBlock
        .where(status: "processed")
        .maximum(:height)
        .to_i
    else
      0
    end
end

def elapsed_ms(started_at)
  (
    (
      Process.clock_gettime(
        Process::CLOCK_MONOTONIC
      ) - started_at
    ) * 1000
  ).round
end


end
end
