# frozen_string_literal: true

module ExchangeLike
  class TopAddressesQuery
    def initialize(limit: 10)
      @limit = limit.to_i
    end

    def call
      ExchangeAddress
        .operational
        .order(occurrences: :desc)
        .limit(@limit)
    end
  end
end
