# frozen_string_literal: true

module System
  class SidekiqEnqueueOnce
    def self.call(queue:, job_class:, max_queue_size: 2)
      allowed =
        System::SidekiqBackpressure.allow?(
          queue: queue,
          job_class: job_class,
          max_queue_size: max_queue_size
        )

      unless allowed
        Rails.logger.info(
          "[enqueue_once] skip #{job_class} queue=#{queue} backpressure"
        )

        return false
      end

      yield
      true
    end
  end
end