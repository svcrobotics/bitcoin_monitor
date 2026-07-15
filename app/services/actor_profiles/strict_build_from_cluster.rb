# frozen_string_literal: true

module ActorProfiles
class StrictBuildFromCluster
SOURCE = "actor_profiles_strict_build_from_cluster"
PROFILE_VERSION = "strict_v3_core"
UNSPECIFIED_VERSION = Object.new.freeze

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

def self.call(cluster_id:, composition_version: UNSPECIFIED_VERSION)
  new(
    cluster_id: cluster_id,
    composition_version: composition_version
  ).call
end

def initialize(cluster_id:, composition_version: UNSPECIFIED_VERSION)
  @cluster_id = normalize_positive_integer(cluster_id, :cluster_id)
  @legacy = composition_version.equal?(UNSPECIFIED_VERSION)
  @composition_version =
    normalize_positive_integer(composition_version, :composition_version) unless @legacy
end

def call
  return build_profile if @legacy

  with_versioned_session_lock { build_profile }
end

private

def build_profile
  started_at =
    Process.clock_gettime(
      Process::CLOCK_MONOTONIC
    )

  ActiveRecord::Base.transaction(
    isolation: :repeatable_read
  ) do
    if @legacy && !acquire_cluster_build_lock
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

    requested_version =
      @legacy ? cluster_composition_version : @composition_version
    profile = ActorProfile.lock.find_by(cluster_id: cluster.id)

    version_result = version_result_for(
      cluster: cluster,
      profile: profile,
      requested_version: requested_version,
      cluster_composition_version: cluster_composition_version
    )
    return version_result if version_result

    cluster_tip = current_cluster_tip
    layer1_tip = current_layer1_tip

    raise "Cluster strict tip missing" if cluster_tip.zero?
    raise "Layer1 processed tip missing" if layer1_tip.zero?

    unless cluster_tip == layer1_tip
      raise ActorProfiles::DeferredSnapshotError.new(
        "Layer1 and Cluster strict tips are not aligned " \
        "cluster_tip=#{cluster_tip} " \
        "layer1_tip=#{layer1_tip}",
        cluster_id: cluster.id,
        cluster_composition_version: cluster_composition_version,
        reason: "strict_tips_not_aligned",
        details: {
          cluster_tip: cluster_tip,
          layer1_tip: layer1_tip
        }
      )
    end

    address_spend_checkpoint = certified_address_spend_checkpoint!(cluster_tip)

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

    stats = compute_source_stats(cluster)

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

    profile ||= ActorProfile.new(cluster_id: cluster.id)

    profile.assign_attributes(
      balance_btc:
        stats[:balance_btc],

      total_received_btc:
        nil,

      total_sent_btc:
        stats[:total_sent_btc],

      net_btc:
        stats[:net_btc],

      tx_count:
        stats[:tx_count],

      inflow_count:
        nil,

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
          stats[:total_sent_btc].to_s("F")
      },

      metadata: {
        source:
          SOURCE,

        profile_version:
          PROFILE_VERSION,

        strict:
          true,

        computed_at:
          Time.current,

        runtime_ms:
          elapsed_ms(started_at),

        stats_source:
          "addresses_cluster_inputs_utxo_outputs",

        historical_enrichment_status:
          "missing",

        historical_enrichment_source:
          "layer1_tx_output_projection_blocks_projected_future",

        address_spend_projection_height:
          address_spend_checkpoint.height,

        address_spend_projection_hash:
          address_spend_checkpoint.block_hash,

        address_spend_projection_version:
          AddressSpendStat::PROJECTION_VERSION,

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
          ADVISORY_LOCK_NAMESPACE
      }
    )

    profile.save!

    {
      ok: true,
      status: "built",
      legacy: @legacy,

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
        nil,

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
        elapsed_ms(started_at)
    }
  end
end

def version_result_for(cluster:, profile:, requested_version:, cluster_composition_version:)
  if requested_version > cluster_composition_version
    return terminal_version_result(
      status: "refused",
      reason: "future_composition_version",
      cluster: cluster,
      profile: profile,
      requested_version: requested_version,
      cluster_composition_version: cluster_composition_version
    )
  end

  if requested_version < cluster_composition_version
    newer_handoff = ClusterActorProfileHandoff.where(cluster_id: cluster.id)
      .where("composition_version > ?", requested_version)
      .exists?
    return terminal_version_result(
      status: newer_handoff ? "superseded" : "refused",
      reason: newer_handoff ? "newer_durable_handoff" : "newer_handoff_missing",
      cluster: cluster,
      profile: profile,
      requested_version: requested_version,
      cluster_composition_version: cluster_composition_version
    )
  end

  return unless profile_complete_for?(profile, requested_version)

  terminal_version_result(
    status: "already_current",
    reason: "composition_already_materialized",
    cluster: cluster,
    profile: profile,
    requested_version: requested_version,
    cluster_composition_version: cluster_composition_version
  )
end

def profile_complete_for?(profile, requested_version)
  profile&.persisted? &&
    profile.cluster_composition_version.to_i == requested_version &&
    profile.traits.to_h["profile_version"] == PROFILE_VERSION &&
    profile.metadata.to_h["strict"] == true &&
    profile.last_computed_height.present? &&
    !profile.dirty?
end

def terminal_version_result(status:, reason:, cluster:, profile:, requested_version:,
  cluster_composition_version:)
  {
    ok: status != "refused",
    status: status,
    reason: reason,
    legacy: @legacy,
    cluster_id: cluster.id,
    requested_composition_version: requested_version,
    cluster_composition_version: cluster_composition_version,
    actor_profile_composition_version: profile&.cluster_composition_version,
    profile_id: profile&.id
  }
end

def with_versioned_session_lock
  connection = ActiveRecord::Base.connection
  connection.select_value(
    "SELECT pg_advisory_lock(#{ADVISORY_LOCK_NAMESPACE}, #{@cluster_id})"
  )
  yield
ensure
  connection&.select_value(
    "SELECT pg_advisory_unlock(#{ADVISORY_LOCK_NAMESPACE}, #{@cluster_id})"
  )
end

def normalize_positive_integer(value, name)
  integer =
    case value
    when Integer
      value
    when String
      raise ArgumentError unless value.match?(/\A[+-]?\d+\z/)

      Integer(value, 10)
    else
      raise ArgumentError
    end
  raise ArgumentError, "#{name} must be positive" unless integer.positive?

  integer
rescue ArgumentError, TypeError
  raise ArgumentError, "#{name} must be a positive integer"
end

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

def certified_address_spend_checkpoint!(required_height)
  cluster_hash = ClusterProcessedBlock
    .where(height: required_height, status: "processed")
    .pick(:block_hash)
  checkpoint = AddressSpendProjectionBlock.find_by(
    height: required_height,
    status: "completed"
  )
  projection_tip = AddressSpendProjectionBlock
    .where(status: "completed")
    .maximum(:height)
    .to_i
  next_height = AddressSpendStats::NextRecord.call&.height&.to_i

  valid = checkpoint && cluster_hash.present? &&
    checkpoint.block_hash == cluster_hash &&
    projection_tip == required_height &&
    (next_height.nil? || next_height > required_height)
  return checkpoint if valid

  raise ActorProfiles::DeferredSnapshotError.new(
    "AddressSpend projection is not certified at the ActorProfile checkpoint",
    cluster_id: @cluster_id,
    reason: "address_spend_projection_not_ready",
    details: {
      required_height: required_height,
      projection_tip: projection_tip,
      next_record_height: next_height,
      checkpoint_hash_matches: checkpoint&.block_hash == cluster_hash
    }
  )
end

def compute_source_stats(cluster)
  address_scope =
    Address.where(
      cluster_id: cluster.id
    )

  address_row =
    address_scope
      .select(
        "COUNT(*) AS address_count",
        "MIN(first_seen_height) AS first_seen_height",
        "MAX(last_seen_height) AS last_seen_height",
        "MIN(created_at) AS first_seen_at",
        "MAX(updated_at) AS last_seen_at"
      )
      .take

  address_count =
    address_row.address_count.to_i

  if address_count.zero?
    raise(
      "Cluster has no addresses " \
      "cluster_id=#{cluster.id}"
    )
  end

  address_subquery =
    address_scope.select(:address)

  cluster_inputs =
    ClusterInput.where(
      address: address_subquery
    )

  utxos =
    UtxoOutput.where(
      address: address_subquery
    )

  total_sent_btc =
    sum_btc(cluster_inputs)

  balance_btc =
    sum_btc(utxos)

  first_seen_height = [
    cluster.first_seen_height,
    min_height(cluster_inputs),
    min_height(utxos)
  ]
    .compact
    .map(&:to_i)
    .reject(&:zero?)
    .min

  last_seen_height = [
    cluster.last_seen_height,
    max_height(cluster_inputs),
    max_height(utxos)
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

  tx_count =
    distinct_tx_count(cluster.id)

  tx_density =
    if activity_span_blocks.positive?
      (
        BigDecimal(tx_count.to_s) /
        BigDecimal(activity_span_blocks.to_s)
      ).round(4)
    else
      BigDecimal("0")
    end

  received_outputs_count =
    nil

  spent_inputs_count =
    cluster_inputs.count

  live_utxo_count =
    utxos.count

  {
    address_count:
      address_count,

    total_received_btc:
      nil,

    total_sent_btc:
      total_sent_btc,

    balance_btc:
      balance_btc,

    net_btc:
      balance_btc,

    tx_count:
      tx_count,

    spent_tx_count:
      tx_count,

    inflow_count:
      nil,

    outflow_count:
      spent_inputs_count,

    received_outputs_count:
      received_outputs_count,

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
rescue StandardError
  BigDecimal("0")
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

def distinct_tx_count(cluster_id)
  connection =
    ActiveRecord::Base.connection

  parts = []

  cluster_input_txid_column =
    if ClusterInput
         .column_names
         .include?("spent_txid")
      "spent_txid"
    elsif ClusterInput
            .column_names
            .include?("txid")
      "txid"
    end

  if cluster_input_txid_column
    parts << <<~SQL.squish
      SELECT #{
        cluster_input_txid_column
      } AS txid

      FROM #{
        connection.quote_table_name(
          ClusterInput.table_name
        )
      }

      WHERE address IN (
        SELECT address

        FROM #{
          connection.quote_table_name(
            Address.table_name
          )
        }

        WHERE cluster_id = #{cluster_id.to_i}
      )

      AND #{
        cluster_input_txid_column
      } IS NOT NULL
    SQL
  end

  return 0 if parts.empty?

  sql = <<~SQL
    SELECT COUNT(DISTINCT txid) AS count

    FROM (
      #{parts.join("\nUNION\n")}
    ) txids
  SQL

  connection
    .select_value(sql)
    .to_i
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
