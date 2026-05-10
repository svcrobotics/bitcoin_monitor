# frozen_string_literal: true

module Blockchain
  module Buffers
    class SpentOutputBuffer
      KEY = "blockchain:spent_outputs:buffer"

      def initialize(redis: ::Redis.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0")))
        @redis = redis
      end

      def push_many(rows)
        return 0 if rows.blank?

        payloads = rows.map { |row| JSON.generate(row) }

        @redis.pipelined do |pipeline|
          payloads.each do |payload|
            pipeline.rpush(KEY, payload)
          end
        end

        rows.size
      end
    end
  end
end