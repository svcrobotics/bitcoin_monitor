# frozen_string_literal: true

module ExchangeLike
  class AddressScorer
    def score_increment(stat)
      occurrences = stat[:occurrences].to_i
      tx_count    = stat[:txids].size
      active_days = stat[:seen_days].size
      total_btc   = stat[:total_received_btc]

      score = 0
      score += occurrences
      score += [tx_count / 3, 10].min
      score += [active_days * 2, 20].min

      score +=
        if total_btc >= 100.to_d
          20
        elsif total_btc >= 20.to_d
          10
        elsif total_btc >= 5.to_d
          5
        else
          0
        end

      [[score, 1].max, 100].min
    end
  end
end