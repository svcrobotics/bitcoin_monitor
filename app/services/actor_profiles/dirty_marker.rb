# app/services/actor_profiles/dirty_marker.rb
# frozen_string_literal: true

module ActorProfiles
  class DirtyMarker
    KEY = "actor_profiles:dirty_cluster_ids"

    def self.mark(cluster_id)
      new.mark(cluster_id)
    end

    def self.redis
      @redis ||= Redis.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0"))
    end

    def initialize(redis: self.class.redis)
      @redis = redis
    end

    def mark(cluster_id)
      return false if cluster_id.blank?

      @redis.sadd(KEY, cluster_id.to_i)

      true
    end
  end
end