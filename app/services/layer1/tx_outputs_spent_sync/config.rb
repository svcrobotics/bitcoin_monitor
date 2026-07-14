# frozen_string_literal: true

module Layer1
  module TxOutputsSpentSync
    module Config
      TRUE_VALUES = %w[1 true yes on].freeze

      module_function

      def enabled?
        TRUE_VALUES.include?(
          ENV.fetch("TX_OUTPUTS_SPENT_ASYNC", "0").to_s.downcase
        )
      end

      def batch_size
        [ENV.fetch("TX_OUTPUTS_SPENT_ASYNC_BATCH_SIZE", "500").to_i, 1].max
      end

      def max_layer1_lag
        [ENV.fetch("TX_OUTPUTS_SPENT_ASYNC_MAX_LAYER1_LAG", "0").to_i, 0].max
      end

      def retry_wait_seconds
        [ENV.fetch("TX_OUTPUTS_SPENT_ASYNC_RETRY_WAIT_SECONDS", "30").to_i, 5].max
      end

      def max_attempts
        [ENV.fetch("TX_OUTPUTS_SPENT_ASYNC_MAX_ATTEMPTS", "10").to_i, 1].max
      end

      def processing_stale_after_seconds
        [
          ENV.fetch(
            "TX_OUTPUTS_SPENT_SYNC_STALE_AFTER_SECONDS",
            ENV.fetch(
              "TX_OUTPUTS_SPENT_ASYNC_PROCESSING_STALE_AFTER_SECONDS",
              "900"
            )
          ).to_i,
          60
        ].max
      end

      def recovery_stale_after_seconds
        processing_stale_after_seconds
      end

      def recovery_batch_size
        [
          ENV.fetch(
            "TX_OUTPUTS_SPENT_SYNC_RECOVERY_BATCH_SIZE",
            "10"
          ).to_i,
          1
        ].max
      end

      def recovery_status_ttl_seconds
        [
          ENV.fetch(
            "TX_OUTPUTS_SPENT_SYNC_RECOVERY_STATUS_TTL_SECONDS",
            "900"
          ).to_i,
          60
        ].max
      end
    end
  end
end
