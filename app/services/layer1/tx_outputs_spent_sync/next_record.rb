# frozen_string_literal: true

module Layer1
  module TxOutputsSpentSync
    class NextRecord
      def self.call
        Layer1TxOutputSync.transaction do
          record =
            Layer1TxOutputSync
              .eligible_for_spent_sync(
                retry_before: Config.retry_wait_seconds.seconds.ago,
                stale_before: Config.processing_stale_after_seconds.seconds.ago,
                max_attempts: Config.max_attempts
              )
              .order(:height)
              .lock("FOR UPDATE SKIP LOCKED")
              .first

          next unless record

          now = Time.current
          record.update!(
            status: "processing",
            started_at: now,
            last_attempt_at: now,
            completed_at: nil
          )

          record
        end
      end
    end
  end
end
