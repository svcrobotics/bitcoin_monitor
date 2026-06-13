# frozen_string_literal: true

module Layer1
  class CachedHealthSnapshot
    CACHE_KEY = "layer1:health_snapshot"

    def self.read
      Rails.cache.read(CACHE_KEY) || Layer1::HealthSnapshot.call
    end

    def self.refresh!
      snapshot = Layer1::HealthSnapshot.call
      Rails.cache.write(CACHE_KEY, snapshot, expires_in: 30.seconds)
      snapshot
    end
  end
end
