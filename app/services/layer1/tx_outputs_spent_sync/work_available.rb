# frozen_string_literal: true

module Layer1
  module TxOutputsSpentSync
    class WorkAvailable
      def self.call
        Layer1TxOutputSync
          .eligible_for_spent_sync(
            retry_before: Config.retry_wait_seconds.seconds.ago,
            stale_before: Config.processing_stale_after_seconds.seconds.ago,
            max_attempts: Config.max_attempts
          )
          .exists?
      end
    end
  end
end
