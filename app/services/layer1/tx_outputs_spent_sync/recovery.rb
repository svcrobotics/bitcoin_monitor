# frozen_string_literal: true

module Layer1
  module TxOutputsSpentSync
    class Recovery
      def self.call(limit: Config.recovery_batch_size)
        new(limit: limit).call
      end

      def initialize(limit:)
        @limit = [limit.to_i, 1].max
      end

      def call
        cutoff = Config.recovery_stale_after_seconds.seconds.ago

        recovered =
          Layer1TxOutputSync.transaction do
            records =
              Layer1TxOutputSync
                .where(status: "processing")
                .where(
                  "COALESCE(last_attempt_at, started_at, updated_at) < ?",
                  cutoff
                )
                .order(:height)
                .limit(@limit)
                .lock("FOR UPDATE SKIP LOCKED")
                .to_a

            records.each do |record|
              record.update_columns(status: "pending")
            end

            records
          end

        {
          ok: true,
          cutoff: cutoff,
          recovered: recovered.size,
          checkpoint_ids: recovered.map(&:id),
          heights: recovered.map(&:height)
        }
      end
    end
  end
end
