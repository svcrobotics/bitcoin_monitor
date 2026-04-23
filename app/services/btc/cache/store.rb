# frozen_string_literal: true

require "json"

module Btc
  module Cache
    class Store
      class << self
        def cache_enabled?
          ENV["BTC_REDIS_DISABLED"] != "1"
        end

        def fetch_json(key, expires_in: nil)
          return yield if block_given? && !cache_enabled?

          raw = REDIS.get(key)
          return JSON.parse(raw, symbolize_names: true) if raw.present?

          return nil unless block_given?

          value = yield
          write_json(key, value, expires_in: expires_in)
          value
        rescue StandardError => e
          Rails.logger.warn("[btc/cache] fetch_json failed key=#{key} error=#{e.class} #{e.message}")
          block_given? ? yield : nil
        end

        def write_json(key, value, expires_in: nil)
          return value unless cache_enabled?

          payload = JSON.generate(value)

          if expires_in.present?
            REDIS.setex(key, expires_in.to_i, payload)
          else
            REDIS.set(key, payload)
          end

          value
        rescue StandardError => e
          Rails.logger.warn("[btc/cache] write_json failed key=#{key} error=#{e.class} #{e.message}")
          value
        end

        def delete(key)
          REDIS.del(key)
        rescue StandardError => e
          Rails.logger.warn("[btc/cache] delete failed key=#{key} error=#{e.class} #{e.message}")
        end
      end
    end
  end
end