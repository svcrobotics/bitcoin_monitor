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
        priority: priority_for(stats),
        accumulation_score: accumulation_score(stats),
        distribution_score: distribution_score(stats),
        exchange_score: exchange_score(stats),
        whale_score: whale_score(stats),
        etf_score: etf_score(stats),
        service_score: service_score(stats),
        traits: traits(stats),
        metadata: {
          source: SOURCE,
          computed_at: Time.current,
          runtime_ms: elapsed_ms(started_at),
          stats_source: "address_flow_stats",
          computed_height: current_layer1_height
        }
      )

      profile.classification = classify(profile)
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
      row = AddressFlowStat
        .where(cluster_id: @cluster_id)
        .select(
          "COALESCE(SUM(received_btc), 0) AS total_received_btc",
          "COALESCE(SUM(sent_btc), 0) AS total_sent_btc",
          "COALESCE(SUM(net_btc), 0) AS net_btc",
          "COALESCE(SUM(tx_count), 0) AS tx_count",
          "MIN(first_seen_at) AS first_seen_at",
          "MAX(last_seen_at) AS last_seen_at"
        )
        .take

      received_btc = decimal_value(row.total_received_btc)
      sent_btc = decimal_value(row.total_sent_btc)
      net_btc = decimal_value(row.net_btc)
      tx_count = integer_value(row.tx_count)

      {
        balance_btc: net_btc,
        total_received_btc: received_btc,
        total_sent_btc: sent_btc,
        net_btc: net_btc,
        tx_count: tx_count,

        # Pour l’instant AddressFlowStat ne donne pas encore un vrai nombre
        # d’entrées/sorties séparées. On utilise une approximation stable.
        inflow_count: received_btc.positive? ? tx_count : 0,
        outflow_count: sent_btc.positive? ? tx_count : 0,

        first_seen_at: row.first_seen_at,
        last_seen_at: row.last_seen_at
      }
    end

    def accumulation_score(stats)
      score = 0
      score += 30 if stats[:balance_btc] >= 1_000
      score += 30 if stats[:net_btc] > 0
      score += 20 if stats[:outflow_count].to_i < stats[:inflow_count].to_i
      score += 20 if stats[:total_received_btc] > stats[:total_sent_btc]
      [score, 100].min
    end

    def distribution_score(stats)
      score = 0
      score += 40 if stats[:total_sent_btc] > stats[:total_received_btc] * 0.7
      score += 30 if stats[:outflow_count].to_i > stats[:inflow_count].to_i
      score += 30 if stats[:net_btc] < 0
      [score, 100].min
    end

    def whale_score(stats)
      score = 0
      score += 50 if stats[:total_sent_btc] >= 10_000
      score += 30 if stats[:tx_count].to_i < 500
      score += 20 if stats[:outflow_count].to_i < 100
      [score, 100].min
    end

    def exchange_score(stats)
      score = 0
      score += 40 if stats[:tx_count].to_i >= 10_000
      score += 30 if stats[:inflow_count].to_i >= 5_000
      score += 30 if stats[:outflow_count].to_i >= 5_000
      [score, 100].min
    end

    def etf_score(stats)
      score = 0
      score += 50 if stats[:total_sent_btc] >= 50_000
      score += 30 if stats[:tx_count].to_i < 500
      score += 20 if stats[:outflow_count].to_i < 50
      [score, 100].min
    end

    def service_score(stats)
      score = 0
      score += 50 if stats[:tx_count].to_i >= 5_000
      score += 25 if stats[:inflow_count].to_i >= 2_000
      score += 25 if stats[:outflow_count].to_i >= 2_000
      [score, 100].min
    end

    def traits(stats)
      {
        accumulator: stats[:net_btc] > 0,
        large_holder: stats[:balance_btc] >= 1_000,
        very_large_holder: stats[:balance_btc] >= 10_000,
        low_outflow_ratio: stats[:outflow_count].to_i < stats[:inflow_count].to_i * 0.2,
        high_activity: stats[:tx_count].to_i >= 5_000
      }
    end

    def classify(profile)
      scores = {
        "etf_like" => profile.etf_score.to_i,
        "exchange_like" => profile.exchange_score.to_i,
        "whale_like" => profile.whale_score.to_i,
        "service_like" => profile.service_score.to_i
      }

      label, score = scores.max_by { |_label, value| value }
      score >= 60 ? label : "unknown"
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

    def priority_for(stats)
      return "heavy" if stats[:tx_count].to_i >= 100_000
      return "heavy" if stats[:total_received_btc].to_d >= 50_000
      return "medium" if stats[:tx_count].to_i >= 10_000
      return "medium" if stats[:total_received_btc].to_d >= 1_000

      "light"
    end
  end
end