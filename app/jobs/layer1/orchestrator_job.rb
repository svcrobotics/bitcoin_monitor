# frozen_string_literal: true
require "sidekiq/api"
module Layer1
  class OrchestratorJob < ApplicationJob
    queue_as :process

    OUTPUTS_KEY = Blockchain::Buffers::OutputBuffer::KEY
    SPENT_KEY = "blockchain:spent_outputs:buffer"
    LOCK_KEY = Layer1::DrainJob::LOCK_KEY

    def perform
      orchestration =
        Blockchain::Orchestration::Layer1Orchestrator.new.call

      redis = Redis.new(
        url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0")
      )

      outputs = redis.llen(OUTPUTS_KEY)
      spent = redis.llen(SPENT_KEY)

      drain_queue_size = Sidekiq::Queue.new("layer1_drain").size
      drain_locked = redis.exists?(LOCK_KEY)

      drain_enqueued = false

      if (outputs.positive? || spent.positive?) &&
          drain_queue_size.zero? &&
          !drain_locked
        Layer1::DrainJob.perform_later
        drain_enqueued = true
      end

      Rails.logger.info(
        "[layer1_orchestrator] " \
        "orchestration_ok=#{orchestration[:ok]} " \
        "backfill=#{orchestration.dig(:backfill, :ingested_count)} " \
        "processing=#{orchestration.dig(:processing, :enqueued)} " \
        "outputs=#{outputs} " \
        "spent=#{spent} " \
        "drain_queue=#{drain_queue_size} " \
        "drain_locked=#{drain_locked} " \
        "drain_enqueued=#{drain_enqueued}"
      )

      orchestration.merge(
        drain: {
          outputs: outputs,
          spent: spent,
          queue_size: drain_queue_size,
          locked: drain_locked,
          enqueued: drain_enqueued
        }
      )
    end
  end
end