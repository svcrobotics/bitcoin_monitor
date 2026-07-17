# frozen_string_literal: true

module ClusterTransactionProjection
  class BackfillSliceJob < ApplicationJob
    queue_as :cluster_transaction_projection

    LOCK_KEY =
      "cluster_transaction_projection:backfill_slice:lock"

    SCHEDULE_KEY =
      "cluster_transaction_projection:backfill_slice:scheduled"

    MARKER_TTL_SECONDS = 5.minutes.to_i

    def self.mark_scheduled!
      Sidekiq.redis do |redis|
        redis.set(
          SCHEDULE_KEY,
          Time.current.iso8601(6),
          ex: MARKER_TTL_SECONDS
        )
      end
    end

    def self.clear_scheduled!
      Sidekiq.redis do |redis|
        redis.del(SCHEDULE_KEY)
      end
    end

    def self.lock_present?
      Sidekiq.redis do |redis|
        redis.call("EXISTS", LOCK_KEY, SCHEDULE_KEY).to_i.positive?
      end
    rescue StandardError
      true
    end

    def perform(run_id: nil, budget_seconds: nil)
      self.class.clear_scheduled!

      decision =
        System::PipelineController.decision(
          :cluster_transaction_projection_backfill
        )

      return refused_result(decision) unless
        decision[:allowed] == true &&
        System::PipelineController.work_available?(decision)

      run =
        resolve_run(
          run_id ||
            decision.dig(
              :cluster_transaction_projection_backfill,
              :active_run_id
            )
        )

      return idle_result unless run

      lease =
        StrictPipeline::StrictIoLease.acquire(
          BackfillRunner::OWNER
        )

      return lease_denied_result unless lease

      mark_running!(run)

      result =
        BackfillRunner.call(
          run_id: run.id,
          target_checkpoint_height:
            run.target_checkpoint_height,
          target_checkpoint_hash:
            run.target_checkpoint_hash,
          budget_seconds:
            budget_seconds ||
              OperationalSnapshot.scheduler_budget_seconds,
          min_free_bytes:
            OperationalSnapshot.min_free_bytes,
          external_lease: lease,
          preemption_check:
            method(:preemption_reason)
        )

      result_payload(result)
    rescue StandardError => error
      {
        ok: false,
        reason: :error,
        error: "#{error.class}: #{error.message}"
      }
    ensure
      release_lease(lease) if lease
      clear_running!
    end

    private

    def resolve_run(id)
      return nil if id.blank?

      ClusterTransactionProjectionBackfillRun.find_by(
        id: id
      )
    end

    def preemption_reason(_run)
      System::PipelineController
        .cluster_transaction_projection_backfill_preemption_reason
    end

    def mark_running!(run)
      Sidekiq.redis do |redis|
        redis.set(
          LOCK_KEY,
          {
            run_id: run.id,
            pid: Process.pid,
            started_at: Time.current.iso8601(6)
          }.to_json,
          ex: MARKER_TTL_SECONDS
        )
      end
    end

    def clear_running!
      Sidekiq.redis do |redis|
        redis.del(LOCK_KEY)
      end
    end

    def release_lease(lease)
      StrictPipeline::StrictIoLease.release(
        owner: lease.owner,
        token: lease.token
      )
    end

    def refused_result(decision)
      {
        ok: false,
        reason: decision[:reason],
        state: decision[:state],
        failed_constraints:
          decision[:failed_constraints]
      }
    end

    def idle_result
      {
        ok: true,
        reason: :idle_no_run,
        chunks_executed: 0
      }
    end

    def lease_denied_result
      {
        ok: false,
        reason: :strict_io_lease_denied,
        chunks_executed: 0
      }
    end

    def result_payload(result)
      {
        ok: result.ok,
        reason: result.reason,
        chunks_executed: result.chunks_processed.to_i,
        elapsed_ms: result.elapsed_ms.to_i,
        last_chunk_ms: result.last_chunk_ms,
        facts_inserted: result.facts_inserted.to_i,
        facts_updated: result.facts_updated.to_i,
        rows_scanned: result.rows_scanned.to_i,
        pause_reason: result.pause_reason
      }
    end
  end
end
