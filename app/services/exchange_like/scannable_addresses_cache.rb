# frozen_string_literal: true

module ExchangeLike
  class ScannableAddressesCache
    KEY = "exchange_like:scannable_addresses"
    TTL = 5.minutes

    def self.fetch
      cached = $redis.get(KEY)

      if cached.present?
        return deserialize(cached)
      end

      addresses = load_from_db
      $redis.setex(KEY, TTL, serialize(addresses))

      addresses
    end

    def self.invalidate!
      $redis.del(KEY)
    end

    # ------------------------
    # Internal
    # ------------------------

    def self.load_from_db
      rel =
        if ExchangeAddress.respond_to?(:scannable)
          ExchangeAddress.scannable
        elsif ExchangeAddress.respond_to?(:operational)
          ExchangeAddress.operational
        else
          ExchangeAddress.where.not(address: [nil, ""])
        end

      rel.where.not(address: [nil, ""]).pluck(:address)
    end

    def self.serialize(addresses)
      addresses.join(",")
    end

    def self.deserialize(str)
      str.split(",")
    end
  end
end
