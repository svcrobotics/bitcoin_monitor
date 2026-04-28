# frozen_string_literal: true

module Clusters
  class SqlBatchFlusher
    STREAM = ENV.fetch("CLUSTER_WRITE_STREAM", "cluster:writes")
    LAST_ID_KEY = ENV.fetch("CLUSTER_SQL_FLUSHER_LAST_ID_KEY", "cluster:sql_flusher:last_id")
    BATCH_SIZE = ENV.fetch("CLUSTER_SQL_FLUSHER_BATCH_SIZE", "100").to_i

    def self.call(redis: Redis.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0")))
      new(redis: redis).call
    end

    def initialize(redis:)
      @redis = redis
    end

    def call
      last_id = @redis.get(LAST_ID_KEY) || "0-0"

      entries = @redis.xread(STREAM, last_id, count: BATCH_SIZE, block: 1000)
      return { inserted: 0 } if entries.blank?

      rows = []
      newest_id = last_id

      entries.each do |_stream, messages|
        messages.each do |id, data|
          payload = JSON.parse(data.fetch("payload", "{}"))

          rows << {
            event: data["event"],
            height: payload["height"] || payload["end_height"] || payload["start_height"],
            payload: payload,
            processed_at: Time.current,
            created_at: Time.current,
            updated_at: Time.current
          }

          newest_id = id
        end
      end

      ClusterPipelineEvent.insert_all(rows) if rows.any?
      @redis.set(LAST_ID_KEY, newest_id)

      {
        inserted: rows.size,
        last_id: newest_id
      }
    end
  end
end
