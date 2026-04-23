# frozen_string_literal: true

module ExchangeLike
  class ScannableAddressesCache
    KEY = "exchange_like:scannable_addresses".freeze
    TTL = 5.minutes

    class << self
      def fetch
        cached = REDIS.get(KEY)

        if cached.present?
          return deserialize(cached)
        end

        addresses = load_from_db
        REDIS.setex(KEY, TTL.to_i, serialize(addresses))

        addresses
      rescue StandardError => e
        Rails.logger.warn("[exchange_like/scannable_addresses_cache] fetch failed: #{e.class} #{e.message}")
        load_from_db
      end

      def invalidate!
        REDIS.del(KEY)
      rescue StandardError => e
        Rails.logger.warn("[exchange_like/scannable_addresses_cache] invalidate failed: #{e.class} #{e.message}")
      end

      private

      def load_from_db
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

      def serialize(addresses)
        addresses.join(",")
      end

      def deserialize(str)
        str.split(",")
      end
    end
  end
end