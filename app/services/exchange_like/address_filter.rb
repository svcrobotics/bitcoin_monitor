# frozen_string_literal: true

module ExchangeLike
  class AddressFilter
    def initialize(
      min_occurrences_to_keep:,
      min_tx_count_to_keep:,
      min_active_days_to_keep:
    )
      @min_occurrences_to_keep = min_occurrences_to_keep.to_i
      @min_tx_count_to_keep = min_tx_count_to_keep.to_i
      @min_active_days_to_keep = min_active_days_to_keep.to_i
    end

    def keep?(stat)
      occurrences = stat[:occurrences].to_i
      tx_count    = stat[:txids].size
      active_days = stat[:seen_days].size

      return true if occurrences >= @min_occurrences_to_keep
      return true if tx_count >= @min_tx_count_to_keep
      return true if active_days >= @min_active_days_to_keep && occurrences >= 2

      false
    end
  end
end
