# frozen_string_literal: true

require "json"
require "securerandom"
require "sidekiq/api"

module Layer1
  module TxOutputProjection
    class Recovery
      QUEUE_NAME = "tx_output_projection"
      TARGET_JOB = "Layer1::TxOutputProjectionJob"
      STATUS_KEY = "layer1:tx_output_projection:recovery:last"
      LOCK_KEY = "layer1:tx_output_projection:recovery:lock"
      LOCK_TTL_SECONDS = 900

      def self.call(limit: Config.recovery_batch_size, logger: Rails.logger)
        new(limit: limit, logger: logger).call
      end

      def initialize(limit:, logger:)
        @limit = [limit.to_i, 1].max
        @logger = logger
      end

      def call
        result = base_result

        token = SecureRandom.hex(16)

        unless acquire_lock(token)
          result[:skipped_active] = true
          result[:reason] = "projection_recovery_lock_present"
          return persist_result(result)
        end

        if job_active? || lock_present?
          result[:skipped_active] = true
          result[:reason] = "projection_job_active_or_locked"
          return persist_result(result)
        end

        records = stale_scope.limit(@limit).to_a
        result[:checked] = records.size

        records.each do |record|
          recover_record(record, result)
        end

        persist_result(result)
      ensure
        release_lock(token) if defined?(token) && token.present?
      end

      private

      def base_result
        {
          ok: true,
          checked_at: Time.current,
          stale_after_seconds: Config.recovery_stale_after_seconds,
          checked: 0,
          recovered: 0,
          finalized: 0,
          retried: 0,
          failed: 0,
          partial: 0,
          skipped_active: false,
          heights: [],
          errors: {}
        }
      end

      def stale_scope
        Layer1TxOutputProjectionBlock
          .where(status: "processing")
          .where("attempts < ?", Config.max_attempts)
          .where(
            "COALESCE(last_attempt_at, started_at, updated_at) < ?",
            Config.recovery_stale_after_seconds.seconds.ago
          )
          .order(:height)
      end

      def recover_record(record, result)
        actual_count =
          TxOutput.where(block_height: record.height).count

        expected_count =
          record.expected_outputs_count.to_i

        result[:partial] += 1 if actual_count.positive? &&
                                actual_count < expected_count

        if actual_count == expected_count
          finalize_complete_record(record, actual_count, result)
        else
          retry_projection(record, actual_count, result)
        end
      rescue StandardError => error
        mark_failed(record, error)
        result[:failed] += 1
        result[:errors][record.height] =
          "#{error.class}: #{error.message}".first(500)
      end

      def finalize_complete_record(record, actual_count, result)
        actual_value =
          TxOutput
            .where(block_height: record.height)
            .sum(:amount_btc)

        expected_value =
          BigDecimal(record.expected_outputs_value_btc.to_s)

        unless expected_value == BigDecimal(actual_value.to_s)
          raise(
            "recovery projected value mismatch height=#{record.height} " \
            "expected=#{expected_value.to_s('F')} " \
            "actual=#{BigDecimal(actual_value.to_s).to_s('F')}"
          )
        end

        record.update!(
          status: "projected",
          attempts: record.attempts.to_i + 1,
          started_at: Time.current,
          last_attempt_at: Time.current,
          projected_outputs_count: actual_count,
          projected_outputs_value_btc: actual_value,
          rows_inserted: 0,
          rows_skipped: actual_count,
          completed_at: Time.current,
          last_error: nil
        )

        result[:recovered] += 1
        result[:finalized] += 1
        result[:heights] << record.height
      end

      def retry_projection(record, _actual_count, result)
        ProjectHeight.call(
          projection_block: record,
          logger: @logger
        )

        result[:recovered] += 1
        result[:retried] += 1
        result[:heights] << record.height
      end

      def mark_failed(record, error)
        record.update_columns(
          status: "failed",
          attempts: record.attempts.to_i + 1,
          last_attempt_at: Time.current,
          completed_at: nil,
          last_error: "#{error.class}: #{error.message}".first(2_000),
          updated_at: Time.current
        )
      end

      def job_active?
        Sidekiq::WorkSet.new.any? do |_process_id, _thread_id, work|
          payload =
            if work.respond_to?(:payload)
              work.payload
            else
              work.to_h
            end

          payload.to_s.include?(TARGET_JOB)
        end
      rescue StandardError
        false
      end

      def lock_present?
        Sidekiq.redis do |redis|
          value =
            redis.call(
              "EXISTS",
              Layer1::TxOutputProjectionJob::LOCK_KEY
            )

          value == true || value.to_i.positive?
        end
      rescue StandardError
        false
      end

      def acquire_lock(token)
        Sidekiq.redis do |redis|
          !!redis.set(
            LOCK_KEY,
            token,
            nx: true,
            ex: LOCK_TTL_SECONDS
          )
        end
      rescue StandardError
        false
      end

      def release_lock(token)
        Sidekiq.redis do |redis|
          redis.del(LOCK_KEY) if redis.get(LOCK_KEY) == token
        end
      rescue StandardError => error
        @logger.warn(
          "[tx_output_projection_recovery] lock_release_failed " \
          "#{error.class}: #{error.message}"
        )
      end

      def persist_result(result)
        payload =
          result.merge(
            checked_at: result[:checked_at].iso8601(6)
          )

        Sidekiq.redis do |redis|
          redis.set(
            STATUS_KEY,
            JSON.generate(payload),
            ex: Config.recovery_status_ttl_seconds
          )
        end

        @logger.info("[tx_output_projection_recovery] #{result.inspect}")

        result
      rescue StandardError => error
        @logger.warn(
          "[tx_output_projection_recovery] status_save_failed " \
          "#{error.class}: #{error.message}"
        )

        result
      end
    end
  end
end
