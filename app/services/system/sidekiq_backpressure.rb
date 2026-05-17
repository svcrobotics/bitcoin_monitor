# frozen_string_literal: true

require "sidekiq/api"

module System
  class SidekiqBackpressure
    DEFAULT_MAX_QUEUE_SIZE = 2

    def self.allow?(queue:, job_class:, max_queue_size: DEFAULT_MAX_QUEUE_SIZE)
      new(
        queue: queue,
        job_class: job_class,
        max_queue_size: max_queue_size
      ).allow?
    end

    def initialize(queue:, job_class:, max_queue_size:)
      @queue = queue.to_s
      @job_class = job_class.to_s
      @max_queue_size = max_queue_size.to_i
    end

    def allow?
      return false if queue_size >= @max_queue_size
      return false if queued?
      return false if running?

      true
    rescue StandardError => e
      Rails.logger.warn(
        "[sidekiq_backpressure] probe_failed job=#{@job_class} queue=#{@queue} #{e.class}: #{e.message}"
      )

      false
    end

    private

    def queue_size
      Sidekiq::Queue.new(@queue).size
    end

    def queued?
      Sidekiq::Queue.new(@queue).any? do |job|
        sidekiq_job_class(job.item) == @job_class
      end
    end

    def running?
      Sidekiq::Workers.new.any? do |_, _, work|
        payload = work.payload
        payload = JSON.parse(payload) if payload.is_a?(String)

        work.queue.to_s == @queue &&
          sidekiq_job_class(payload) == @job_class
      end
    end

    def sidekiq_job_class(payload)
      args = payload["args"] || []
      first_arg = args.first

      payload["wrapped"].presence ||
        (first_arg.is_a?(Hash) ? first_arg["job_class"].presence : nil) ||
        payload["class"].presence
    end
  end
end
