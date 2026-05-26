# app/services/actor_profiles/apply_deltas.rb
# frozen_string_literal: true

module ActorProfiles
  class ApplyDeltas
    def self.call(cluster_id:)
      new(cluster_id: cluster_id).call
    end

    def initialize(cluster_id:)
      @cluster_id = cluster_id.to_i
    end

    def call
      profile = ActorProfile.find_or_initialize_by(cluster_id: @cluster_id)

      deltas = ActorProfileDelta
        .where(cluster_id: @cluster_id, processed_at: nil)
    
      return nil if deltas.empty?

      stats = aggregate_deltas(deltas)

      apply_stats(profile, stats)

      profile.classification = classify(profile)
      profile.save!

      deltas.update_all(
        processed_at: Time.current,
        updated_at: Time.current
      )

      ActorLabels::RefreshFromActorProfile.call(actor_profile: profile)

      profile
    end

    private

    def aggregate_deltas(deltas)
      row = deltas
        .select(
          "COALESCE(SUM(received_btc_delta), 0) AS received_btc",
          "COALESCE(SUM(sent_btc_delta), 0) AS sent_btc",
          "COALESCE(SUM(net_btc_delta), 0) AS net_btc",
          "COALESCE(SUM(tx_count_delta), 0) AS tx_count",
          "MIN(first_seen_at) AS first_seen_at",
          "MAX(last_seen_at) AS last_seen_at",
          "MAX(block_height) AS max_block_height"
        )
        .take

      {
        received_btc: decimal_value(row.received_btc),
        sent_btc: decimal_value(row.sent_btc),
        net_btc: decimal_value(row.net_btc),
        tx_count: row.tx_count.to_i,
        first_seen_at: row.first_seen_at,
        last_seen_at: row.last_seen_at,
        max_block_height: row.max_block_height.to_i
      }
    end

    def apply_stats(profile, stats)
      old_received = profile.total_received_btc.to_d
      old_sent = profile.total_sent_btc.to_d
      old_tx_count = profile.tx_count.to_i

      new_received = old_received + stats[:received_btc]
      new_sent = old_sent + stats[:sent_btc]
      new_net = new_received - new_sent
      new_tx_count = old_tx_count + stats[:tx_count]

      computed_stats = {
        balance_btc: new_net,
        total_received_btc: new_received,
        total_sent_btc: new_sent,
        net_btc: new_net,
        tx_count: new_tx_count,
        inflow_count: profile.inflow_count.to_i + (stats[:received_btc].positive? ? stats[:tx_count] : 0),
        outflow_count: profile.outflow_count.to_i + (stats[:sent_btc].positive? ? stats[:tx_count] : 0),
        first_seen_at: [profile.first_seen_at, stats[:first_seen_at]].compact.min,
        last_seen_at: [profile.last_seen_at, stats[:last_seen_at]].compact.max
      }

      profile.assign_attributes(
        balance_btc: computed_stats[:balance_btc],
        total_received_btc: computed_stats[:total_received_btc],
        total_sent_btc: computed_stats[:total_sent_btc],
        net_btc: computed_stats[:net_btc],
        tx_count: computed_stats[:tx_count],
        inflow_count: computed_stats[:inflow_count],
        outflow_count: computed_stats[:outflow_count],
        first_seen_at: computed_stats[:first_seen_at],
        last_seen_at: computed_stats[:last_seen_at],
        last_computed_height: stats[:max_block_height],
        dirty: false,
        priority: priority_for(computed_stats),
        accumulation_score: accumulation_score(computed_stats),
        distribution_score: distribution_score(computed_stats),
        exchange_score: exchange_score(computed_stats),
        whale_score: whale_score(computed_stats),
        etf_score: etf_score(computed_stats),
        service_score: service_score(computed_stats),
        traits: traits(computed_stats),
        metadata: {
          source: "actor_profiles_apply_deltas",
          computed_at: Time.current,
          max_delta_height: stats[:max_block_height],
          delta_tx_count: stats[:tx_count]
        }
      )
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

    def priority_for(stats)
      return "heavy" if stats[:tx_count].to_i >= 100_000
      return "heavy" if stats[:total_received_btc].to_d >= 50_000
      return "medium" if stats[:tx_count].to_i >= 10_000
      return "medium" if stats[:total_received_btc].to_d >= 1_000

      "light"
    end

    def decimal_value(value)
      BigDecimal(value.to_s)
    rescue
      BigDecimal("0")
    end
  end
end
