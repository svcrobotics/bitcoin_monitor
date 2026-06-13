# app/services/actor_profiles/build_from_cluster.rb
# frozen_string_literal: true

module ActorProfiles
  class BuildFromCluster
    SOURCE = "actor_profiles_build_from_cluster"

    def self.call(cluster_id:)
      new(cluster_id).call
    end

    def initialize(cluster_id)
      @cluster_id = cluster_id.to_i
    end

    def call
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      profile = ActorProfile.find_or_initialize_by(cluster_id: @cluster_id)
      stats = compute_stats

      scores = ActorProfiles::ScoreCalculator.call(stats)

      profile.assign_attributes(
        balance_btc: stats[:balance_btc],
        total_received_btc: stats[:total_received_btc],
        total_sent_btc: stats[:total_sent_btc],
        net_btc: stats[:net_btc],
        tx_count: stats[:tx_count],
        inflow_count: stats[:inflow_count],
        outflow_count: stats[:outflow_count],
        first_seen_at: stats[:first_seen_at],
        last_seen_at: stats[:last_seen_at],
        last_computed_height: current_layer1_height,
        dirty: false,

        priority: scores[:priority],
        accumulation_score: scores[:accumulation_score],
        distribution_score: scores[:distribution_score],
        exchange_score: scores[:exchange_score],
        whale_score: scores[:whale_score],
        etf_score: scores[:etf_score],
        service_score: scores[:service_score],
        traits: scores[:traits],

        metadata: {
          source: SOURCE,
          computed_at: Time.current,
          runtime_ms: elapsed_ms(started_at),
          stats_source: "addresses_and_cluster_inputs",
          computed_height: current_layer1_height
        }
      )

      profile.classification = scores[:classification]
      profile.save!

      Rails.logger.info(
        "[actor_profile] built cluster_id=#{@cluster_id} " \
        "profile_id=#{profile.id} classification=#{profile.classification} " \
        "tx_count=#{profile.tx_count} runtime_ms=#{elapsed_ms(started_at)}"
      )

      profile
    end

    private

    def compute_stats
      address_row = Address
        .where(cluster_id: @cluster_id)
        .select(
          "COUNT(*) AS address_count",
          "COALESCE(SUM(total_received_sats), 0) AS total_received_sats",
          "COALESCE(SUM(total_sent_sats), 0) AS total_sent_sats",
          "MIN(created_at) AS first_seen_at",
          "MAX(updated_at) AS last_seen_at"
        )
        .take

      tx_row = ClusterInput
        .joins("INNER JOIN addresses ON addresses.address = cluster_inputs.address")
        .where(addresses: { cluster_id: @cluster_id })
        .select(
          "COUNT(*) AS tx_count",
          "COUNT(*) FILTER (WHERE cluster_inputs.amount_btc > 0) AS inflow_count",
          "COUNT(*) FILTER (WHERE cluster_inputs.spent = TRUE) AS outflow_count"
        )
        .take

      received_btc = decimal_value(address_row.total_received_sats) / 100_000_000
      sent_btc = decimal_value(address_row.total_sent_sats) / 100_000_000
      net_btc = received_btc - sent_btc
      tx_count = integer_value(tx_row.tx_count)

      {
        balance_btc: net_btc,
        total_received_btc: received_btc,
        total_sent_btc: sent_btc,
        net_btc: net_btc,
        tx_count: tx_count,
        inflow_count: integer_value(tx_row.inflow_count),
        outflow_count: integer_value(tx_row.outflow_count),
        first_seen_at: address_row.first_seen_at,
        last_seen_at: address_row.last_seen_at
      }
    end

    def decimal_value(value)
      BigDecimal(value.to_s)
    rescue
      BigDecimal("0")
    end

    def integer_value(value)
      value.to_i
    rescue
      0
    end

    def elapsed_ms(started_at)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
    end

    def current_layer1_height
      @current_layer1_height ||= begin
        if defined?(BlockBufferModel)
          BlockBufferModel.maximum(:height).to_i
        else
          0
        end
      rescue
        0
      end
    end
  end
end