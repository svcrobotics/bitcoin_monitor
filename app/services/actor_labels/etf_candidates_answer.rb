# frozen_string_literal: true

module ActorLabels
  class EtfCandidatesAnswer
    def self.call(limit: 10)
      new(limit: limit).call
    end

    def initialize(limit:)
      @limit = limit.to_i
    end

    def call
      labels = ActorLabel
        .where(label: "etf_candidate")
        .includes(:actor_profile)
        .order(confidence: :desc)
        .limit(@limit)

      profiles = labels.map(&:actor_profile).compact

      {
        title: "ETF candidates",
        count: labels.count,
        total_balance_btc: profiles.sum { |p| p.balance_btc.to_d },
        candidates: labels.map do |label|
          profile = label.actor_profile

          {
            cluster_id: label.cluster_id,
            confidence: label.confidence,
            balance_btc: profile&.balance_btc,
            total_received_btc: profile&.total_received_btc,
            total_sent_btc: profile&.total_sent_btc,
            net_btc: profile&.net_btc,
            tx_count: profile&.tx_count,
            whale_score: profile&.whale_score,
            etf_score: profile&.etf_score,
            classification: profile&.classification,
            last_seen_at: profile&.last_seen_at
          }
        end
      }
    end
  end
end
