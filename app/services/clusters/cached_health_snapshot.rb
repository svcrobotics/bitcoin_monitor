# frozen_string_literal: true

module Clusters
  class CachedHealthSnapshot
    CACHE_KEY = "clusters:health_snapshot"

    def self.read
      Rails.cache.read(CACHE_KEY) || Clusters::HealthSnapshot.call
    end

    def self.refresh!
      snapshot = Clusters::HealthSnapshot.call
      Rails.cache.write(CACHE_KEY, snapshot, expires_in: 30.seconds)
      snapshot
    end
  end
end
