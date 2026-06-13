# frozen_string_literal: true
require "sidekiq/api"
module Layer1
  class OrchestratorJob < ApplicationJob
    queue_as :process

    OUTPUTS_KEY = Blockchain::Buffers::OutputBuffer::KEY
    SPENT_KEY = "blockchain:spent_outputs:buffer"
    LOCK_KEY = Layer1::DrainJob::LOCK_KEY

    def perform
      redis = Redis.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0"))

      outputs = redis.llen(OUTPUTS_KEY)
      spent = redis.llen(SPENT_KEY)

      drain_queue_size = Sidekiq::Queue.new("layer1_drain").size
      drain_locked = redis.exists?(LOCK_KEY)

      if (outputs.positive? || spent.positive?) && drain_queue_size.zero? && !drain_locked
        Layer1::DrainJob.perform_later
      end

      Rails.logger.info(
        "[layer1_orchestrator] outputs=#{outputs} spent=#{spent} drain_queue=#{drain_queue_size} drain_locked=#{drain_locked}"
      )
    end
  end
end