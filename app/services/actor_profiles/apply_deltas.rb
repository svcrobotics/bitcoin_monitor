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

      profile.classification = profile.metadata["classification"]
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

      scores = ActorProfiles::ScoreCalculator.call(computed_stats)

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
        priority: scores[:priority],
        accumulation_score: scores[:accumulation_score],
        distribution_score: scores[:distribution_score],
        exchange_score: scores[:exchange_score],
        whale_score: scores[:whale_score],
        etf_score: scores[:etf_score],
        service_score: scores[:service_score],
        traits: scores[:traits],
        metadata: {
          source: "actor_profiles_apply_deltas",
          computed_at: Time.current,
          max_delta_height: stats[:max_block_height],
          delta_tx_count: stats[:tx_count],
          classification: scores[:classification]
        }
      )
    end

    def decimal_value(value)
      BigDecimal(value.to_s)
    rescue StandardError
      BigDecimal("0")
    end
  end
end