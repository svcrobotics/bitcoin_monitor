# frozen_string_literal: true

module ActorLabels
  class CachedHealthSnapshot
    CACHE_KEY = "actor_labels:health_snapshot"

    def self.read
      Rails.cache.read(CACHE_KEY) || ActorLabels::HealthSnapshot.call
    end

    def self.refresh!
      snapshot = ActorLabels::HealthSnapshot.call
      Rails.cache.write(CACHE_KEY, snapshot, expires_in: 30.seconds)
      snapshot
    end
  end
end
