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
      rel =
        if ExchangeAddress.respond_to?(:scannable)
          ExchangeAddress.scannable
        elsif ExchangeAddress.respond_to?(:operational)
          ExchangeAddress.operational
        else
          ExchangeAddress.where.not(address: [nil, ""])
        end

      addresses =
        rel
          .where.not(address: [nil, ""])
          .pluck(:address)
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