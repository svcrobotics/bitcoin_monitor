# frozen_string_literal: true

module Blockchain
  module Orchestration
    class Layer1Orchestrator
      LOCK_KEY = "layer1_orchestrator_lock"
      LOCK_TTL = 15.minutes.to_i

      def initialize(redis: ::Redis.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0")))
        @redis = redis
      end

      def call
        unless acquire_lock
          return skipped("lock already present")
        end

        started_at = Time.current

        backfill = Blockchain::Orchestration::BackfillMissingBlocks.new.call
        requeue_stuck = Blockchain::Orchestration::RequeueStuckBlocks.new.call
        retry_failed = Blockchain::Orchestration::RetryFailedBlocks.new.call
        processing = Blockchain::State::ProcessingRunner.new.call
        flush = { skipped: true, reason: "handled by dedicated flusher cron" }
        pipeline = System::BlockchainPipelineStatus.call

        finished_at = Time.current

        {
          ok: true,
          backfill: backfill,
          requeue_stuck: requeue_stuck,
          retry_failed: retry_failed,
          processing: processing,
          flush: flush,
          pipeline: pipeline,
          started_at: started_at,
          finished_at: finished_at,
          duration_ms: ((finished_at - started_at) * 1000).round
        }
      rescue StandardError => e
        {
          ok: false,
          error_class: e.class.name,
          message: e.message,
          started_at: started_at,
          finished_at: Time.current
        }
      ensure
        release_lock if @lock_acquired
      end

      private

      def acquire_lock
        @lock_acquired = @redis.set(
          LOCK_KEY,
          Time.current.to_i,
          nx: true,
          ex: LOCK_TTL
        )

        @lock_acquired
      end

      def release_lock
        @redis.del(LOCK_KEY)
      end

      def skipped(reason)
        {
          ok: true,
          skipped: true,
          reason: reason,
          at: Time.current
        }
      end
    end
  end
end