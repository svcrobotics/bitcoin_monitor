# frozen_string_literal: true

require "sidekiq/api"

module System
  class SidekiqStatus
    def self.call
      new.call
    end

    def call
      stats = Sidekiq::Stats.new
      processes = Sidekiq::ProcessSet.new
      queue = Sidekiq::Queue.new

      {
        status: compute_status(stats, processes),
        queue_size: queue.size,
        processed: stats.processed,
        failed: stats.failed,
        scheduled_size: stats.scheduled_size,
        retry_size: stats.retry_size,
        dead_size: stats.dead_size,
        processes_size: processes.size,
        busy: processes.sum { |p| p["busy"].to_i },
        concurrency: processes.sum { |p| p["concurrency"].to_i },
        latency: queue.latency.round(1),
        jobs_by_class: jobs_by_class(queue)
      }
    rescue StandardError => e
      {
        status: "error",
        error: "#{e.class}: #{e.message}"
      }
    end

    private

    def compute_status(stats, processes)
      return "critical" if processes.size.zero?
      return "warning" if stats.retry_size.to_i.positive?
      return "warning" if stats.dead_size.to_i.positive?

      "ok"
    end

    def jobs_by_class(queue)
      queue.each_with_object(Hash.new(0)) do |job, counts|
        wrapped = job.item.dig("wrapped")
        klass = wrapped.presence || job.klass
        counts[klass] += 1
      end
    end
    
  end
end
