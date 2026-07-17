# frozen_string_literal: true

module Layer1
  class StrictTipSyncJob
    include Sidekiq::Job

    sidekiq_options queue: :layer1_strict, retry: false

    DEFAULT_MAX_BLOCKS = 3
    POST_COMPLETION_HANDOFF_DELAY = 2.seconds

    def perform(strict_io_token = nil)
      scheduler_wakeup =
        nil

      max_blocks =
        ENV.fetch("LAYER1_STRICT_TIP_SYNC_MAX_BLOCKS", DEFAULT_MAX_BLOCKS).to_i

      unless strict_io_token.present? &&
             StrictPipeline::StrictIoLease.renew(
               owner: "layer1",
               token: strict_io_token
             )
        Rails.logger.info(
          "[layer1_strict_tip_sync_job] " \
          "skipped reason=strict_io_lease_denied"
        )

        request_scheduler_wakeup_once(
          reason: "layer1_strict_io_lease_denied",
          wait: 30.seconds
        )

        return {
          ok: true,
          status: "skipped",
          reason: "strict_io_lease_denied"
        }
      end

      Rails.logger.info(
        "[layer1_strict_tip_sync_job] start max_blocks=#{max_blocks}"
      )

      result =
        Layer1::StrictTipSyncer.call(
          max_blocks: max_blocks,
          strict_io_token: strict_io_token
        )

      log_result(result)

      scheduler_wakeup =
        scheduler_wakeup_after_result(result)

      result
    rescue StandardError => e
      Rails.logger.error(
        "[layer1_strict_tip_sync_job] error #{e.class}: #{e.message}\n" \
        "#{e.backtrace&.first(20)&.join("\n")}"
      )

      scheduler_wakeup ||=
        {
          reason: "layer1_failed",
          wait: 30.seconds
        }

      raise
    ensure
      if strict_io_token.present?
        StrictPipeline::StrictIoLease.release(
          owner: "layer1",
          token: strict_io_token
        )
      end

      request_scheduler_wakeup_once(**scheduler_wakeup) if
        scheduler_wakeup
    end

    private

    def scheduler_wakeup_after_result(result)
      if result[:ok] &&
         layer1_backlog_remaining?(result)
        return {
          reason: "layer1_block_completed_with_backlog",
          wait: POST_COMPLETION_HANDOFF_DELAY
        }
      end

      return nil if result[:ok]

      {
        reason: "layer1_failed",
        wait: 30.seconds
      }
    end

    def request_scheduler_wakeup_once(
      reason:,
      wait: 0.seconds
    )
      StrictPipeline::SchedulerWakeup.request!(
        reason: reason,
        wait: wait
      )
    end

    def layer1_backlog_remaining?(result)
      best_height =
        fresh_bitcoin_core_height(
          fallback: result[:best_height]
        )

      processed_height =
        fresh_layer1_processed_height(
          fallback: result[:continuous_tip]
        )

      return false unless best_height && processed_height

      processed_height.to_i < best_height.to_i
    rescue StandardError => error
      Rails.logger.warn(
        "[layer1_strict_tip_sync_job] " \
        "backlog_check_failed #{error.class}: #{error.message}"
      )

      false
    end

    def fresh_bitcoin_core_height(fallback:)
      BitcoinRpc
        .new
        .getblockcount
        .to_i
    rescue StandardError
      fallback&.to_i
    end

    def fresh_layer1_processed_height(fallback:)
      height =
        BlockBufferModel
          .where(status: "processed")
          .maximum(:height)

      return height.to_i if height

      fallback&.to_i
    end

    def log_result(result)
      if result[:ok]
        Rails.logger.info(
          "[layer1_strict_tip_sync_job] done result=#{result.inspect}"
        )
      elsif result[:status] == "locked"
        Rails.logger.info(
          "[layer1_strict_tip_sync_job] skipped result=#{result.inspect}"
        )
      else
        Rails.logger.error(
          "[layer1_strict_tip_sync_job] failed result=#{result.inspect}"
        )
      end
    end
  end
end
