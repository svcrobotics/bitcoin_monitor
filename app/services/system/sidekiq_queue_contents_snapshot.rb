# frozen_string_literal: true

require "sidekiq/api"

module System
  class SidekiqQueueContentsSnapshot
    QUEUES = %w[
      realtime
      ingest
      process
      p1_exchange
      p2_flows
      p3_clusters_scan
      p3_clusters_refresh
      p3_clusters
      p4_analytics
      default
      low
    ].freeze

    def self.call(limit_per_queue: 20)
      new(limit_per_queue: limit_per_queue).call
    end

    def initialize(limit_per_queue:)
      @limit_per_queue = limit_per_queue
    end

    def call
      QUEUES.map do |queue_name|
        queue = Sidekiq::Queue.new(queue_name)
        jobs = queue.first(@limit_per_queue)

        grouped = Hash.new { |h, k| h[k] = { count: 0, oldest_at: nil, newest_at: nil } }

        jobs.each do |job|
          payload = job.item
          args0 = payload["args"]&.first

          job_class =
            if args0.is_a?(Hash)
              args0["job_class"]
            else
              payload["class"]
            end

          job_class ||= "UnknownJob"

          enqueued_at =
            payload["enqueued_at"] ||
            payload.dig("args", 0, "enqueued_at") ||
            payload["created_at"]

          time = parse_time(enqueued_at)

          grouped[job_class][:count] += 1
          grouped[job_class][:oldest_at] = [grouped[job_class][:oldest_at], time].compact.min
          grouped[job_class][:newest_at] = [grouped[job_class][:newest_at], time].compact.max
        end

        {
          queue: queue_name,
          size: queue.size,
          latency: queue.latency,
          sampled: jobs.size,
          jobs: grouped.map do |klass, data|
            {
              klass: klass,
              count: data[:count],
              oldest_at: data[:oldest_at],
              newest_at: data[:newest_at],
              oldest_age_seconds: data[:oldest_at] ? (Time.current - data[:oldest_at]).to_i : nil
            }
          end.sort_by { |j| -j[:count] }
        }
      end
    end

    private

    def parse_time(value)
      return nil if value.blank?

      if value.is_a?(Numeric)
        Time.zone.at(value.to_f / (value.to_f > 10_000_000_000 ? 1000.0 : 1.0))
      else
        Time.zone.parse(value.to_s)
      end
    rescue StandardError
      nil
    end
  end
end
