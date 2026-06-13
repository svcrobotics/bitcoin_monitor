# frozen_string_literal: true

module ActorProfiles
  class CachedHealthSnapshot
    CACHE_KEY = "actor_profiles:health_snapshot"

    def self.read
      Rails.cache.read(CACHE_KEY) || ActorProfiles::HealthSnapshot.call
    end

    def self.refresh!
      snapshot = ActorProfiles::HealthSnapshot.call
      Rails.cache.write(CACHE_KEY, snapshot, expires_in: 30.seconds)
      snapshot
    end
  end
end

