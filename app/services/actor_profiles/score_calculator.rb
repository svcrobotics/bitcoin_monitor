# frozen_string_literal: true

module ActorProfiles
  class ScoreCalculator
    def self.call(stats)
      new(stats).call
    end

    def initialize(stats)
      @stats = stats
    end

    def call
      scores = {
        accumulation_score: accumulation_score,
        distribution_score: distribution_score,
        whale_score: whale_score,
        exchange_score: exchange_score,
        etf_score: etf_score,
        service_score: service_score,
        traits: traits
      }

      scores.merge(
        classification: classify(scores),
        priority: priority_for
      )
    end

    private

    attr_reader :stats

    def accumulation_score
      score = 0
      score += 30 if stats[:balance_btc].to_d >= 1_000
      score += 30 if stats[:net_btc].to_d > 0
      score += 20 if stats[:outflow_count].to_i < stats[:inflow_count].to_i
      score += 20 if stats[:total_received_btc].to_d > stats[:total_sent_btc].to_d
      [score, 100].min
    end

    def distribution_score
      score = 0
      score += 40 if stats[:total_sent_btc].to_d > stats[:total_received_btc].to_d * 0.7
      score += 30 if stats[:outflow_count].to_i > stats[:inflow_count].to_i
      score += 30 if stats[:net_btc].to_d < 0
      [score, 100].min
    end

    def whale_score
      score = 0

      balance = stats[:balance_btc].to_d
      received = stats[:total_received_btc].to_d

      score += 40 if balance >= 1_000
      score += 30 if balance >= 10_000
      score += 20 if received >= 10_000
      score += 10 if stats[:tx_count].to_i < 500

      [score, 100].min
    end

    def exchange_score
      score = 0
      score += 40 if stats[:tx_count].to_i >= 10_000
      score += 30 if stats[:inflow_count].to_i >= 5_000
      score += 30 if stats[:outflow_count].to_i >= 5_000
      [score, 100].min
    end

    def etf_score
      balance = stats[:balance_btc].to_d
      received = stats[:total_received_btc].to_d
      sent = stats[:total_sent_btc].to_d
      tx_count = stats[:tx_count].to_i
      inflow_count = stats[:inflow_count].to_i
      outflow_count = stats[:outflow_count].to_i

      return 0 if balance < 50_000
      return 0 if tx_count < 10
      return 0 if tx_count > 2_000
      return 0 if received <= sent
      return 0 if outflow_count > inflow_count

      sent_ratio = sent.positive? ? (sent / received) : 0
      balance_ratio = received.positive? ? (balance / received) : 0

      score = 0
      score += 30 if balance >= 50_000
      score += 20 if balance >= 100_000
      score += 20 if balance_ratio >= 0.5
      score += 15 if sent_ratio <= 0.6
      score += 15 if outflow_count <= inflow_count

      [score, 100].min
    end

    def service_score
      score = 0
      score += 50 if stats[:tx_count].to_i >= 5_000
      score += 25 if stats[:inflow_count].to_i >= 2_000
      score += 25 if stats[:outflow_count].to_i >= 2_000
      [score, 100].min
    end

    def traits
      {
        accumulator: stats[:net_btc].to_d > 0,
        large_holder: stats[:balance_btc].to_d >= 1_000,
        very_large_holder: stats[:balance_btc].to_d >= 10_000,
        low_outflow_ratio: stats[:outflow_count].to_i < stats[:inflow_count].to_i * 0.2,
        high_activity: stats[:tx_count].to_i >= 5_000
      }
    end

    def classify(scores)
      candidates = {
        "etf_candidate" => scores[:etf_score].to_i,
        "exchange_like" => scores[:exchange_score].to_i,
        "whale_like" => scores[:whale_score].to_i,
        "service_like" => scores[:service_score].to_i
      }

      label, score = candidates.max_by { |_label, value| value }

      score >= 60 ? label : "unknown"
    end

    def priority_for
      return "heavy" if stats[:tx_count].to_i >= 100_000
      return "heavy" if stats[:total_received_btc].to_d >= 50_000
      return "medium" if stats[:tx_count].to_i >= 10_000
      return "medium" if stats[:total_received_btc].to_d >= 1_000

      "light"
    end
  end
end
