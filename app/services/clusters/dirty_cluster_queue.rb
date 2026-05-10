# frozen_string_literal: true

module Clusters
  class DirtyClusterQueue
    KEY = "clusters:dirty"

    def self.add(cluster_id)
      return if cluster_id.blank?

      redis.sadd(KEY, cluster_id.to_i)
    end

    def self.add_many(cluster_ids)
      ids = Array(cluster_ids).compact.map(&:to_i).uniq
      return 0 if ids.empty?

      redis.sadd(KEY, ids)
    end

    def self.pop(limit: 500)
      Array(redis.spop(KEY, limit)).map(&:to_i)
    end

    def self.size
      redis.scard(KEY).to_i
    end

    def self.redis
      @redis ||= Redis.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0"))
    end
  end
end
