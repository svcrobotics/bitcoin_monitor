# frozen_string_literal: true

require "set"

module ExchangeLike
  class ScannableAddressSet
    Result = Struct.new(
      :addresses,
      :count,
      keyword_init: true
    )

    def call
      addresses =
        ExchangeLike::ScannableAddressesCache
          .fetch
          .map(&:to_s)
          .reject(&:blank?)
          .to_set

      Result.new(
        addresses: addresses,
        count: addresses.size
      )
    end
  end
end