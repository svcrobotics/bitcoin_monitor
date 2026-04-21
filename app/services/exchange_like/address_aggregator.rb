# frozen_string_literal: true

require "set"

module ExchangeLike
  class AddressAggregator
    def initialize
      @stats = {}
    end

    def learn(candidate)
      row = (@stats[candidate.address] ||= new_stat_row)

      row[:occurrences] += 1
      row[:total_received_btc] += candidate.value_btc
      row[:txids] << candidate.txid
      row[:first_seen_at] = [row[:first_seen_at], candidate.seen_at].compact.min
      row[:last_seen_at]  = [row[:last_seen_at], candidate.seen_at].compact.max
      row[:seen_days] << candidate.seen_at.to_date.to_s

      row
    end

    def each(&block)
      @stats.each(&block)
    end

    def size
      @stats.size
    end

    def empty?
      @stats.empty?
    end

    def clear
      @stats.clear
    end

    private

    def new_stat_row
      {
        occurrences: 0,
        total_received_btc: 0.to_d,
        txids: Set.new,
        first_seen_at: nil,
        last_seen_at: nil,
        seen_days: Set.new
      }
    end
  end
end