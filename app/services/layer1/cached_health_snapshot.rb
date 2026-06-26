# frozen_string_literal: true

module Layer1
  class CachedHealthSnapshot
    CACHE_KEY = "layer1:health_snapshot"
    CACHE_TTL = 60.seconds
    RACE_CONDITION_TTL = 10.seconds

    def self.read
      Rails.cache.fetch(
        CACHE_KEY,
        expires_in: CACHE_TTL,
        race_condition_ttl: RACE_CONDITION_TTL
      ) do
        Layer1::HealthSnapshot.call
      end
    end

    def self.refresh!
      snapshot = Layer1::HealthSnapshot.call

      Rails.cache.write(
        CACHE_KEY,
        snapshot,
        expires_in: CACHE_TTL
      )

      snapshot
    end
  end
end
