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
      if result[:ok]
        catchup =
          layer1_catchup_state(result)

        log_continuous_catchup(catchup)

        unless catchup[:known]
          return {
            reason: "layer1_catchup_state_unknown",
            wait: 30.seconds
          }
        end

        return {
          reason:
            catchup[:lag].positive? ?
              "layer1_block_completed_with_backlog" :
              "layer1_caught_up",
          wait: POST_COMPLETION_HANDOFF_DELAY
        }
      end

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

    def layer1_catchup_state(result)
      best_height =
        fresh_bitcoin_core_height(
          fallback: result[:best_height]
        )

      processed_height =
        fresh_layer1_processed_height(
          fallback: result[:continuous_tip]
        )

      build_layer1_catchup_state(
        best_height: best_height,
        processed_height: processed_height
      )
    rescue StandardError => error
      Rails.logger.warn(
        "[layer1_strict_tip_sync_job] " \
        "backlog_check_failed #{error.class}: #{error.message}"
      )

      build_layer1_catchup_state(
        best_height: result[:best_height],
        processed_height: result[:continuous_tip]
      )
    end

    def build_layer1_catchup_state(best_height:, processed_height:)
      unless best_height.nil? || processed_height.nil?
        return {
          known: true,
          best_height: best_height,
          processed_height: processed_height,
          lag: [
            best_height.to_i - processed_height.to_i,
            0
          ].max
        }
      end

      {
        known: false,
        best_height: best_height,
        processed_height: processed_height,
        lag: nil
      }
    end

    def log_continuous_catchup(catchup)
      unless catchup[:known]
        Rails.logger.warn(
          "[layer1_continuous_catchup] " \
          "best_height=#{catchup[:best_height].inspect} " \
          "processed_height=#{catchup[:processed_height].inspect} " \
          "lag=unknown state=unknown"
        )

        return
      end

      if catchup[:lag].positive?
        Rails.logger.info(
          "[layer1_continuous_catchup] " \
          "best_height=#{catchup[:best_height]} " \
          "processed_height=#{catchup[:processed_height]} " \
          "lag=#{catchup[:lag]} " \
          "action=continue " \
          "next_height=#{catchup[:processed_height].to_i + 1}"
        )
      else
        Rails.logger.info(
          "[layer1_continuous_catchup] " \
          "best_height=#{catchup[:best_height]} " \
          "processed_height=#{catchup[:processed_height]} " \
          "lag=0 state=caught_up"
        )
      end
    end

    def fresh_bitcoin_core_height(fallback:)
      BitcoinRpc
        .new
        .getblockcount
        .to_i
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
