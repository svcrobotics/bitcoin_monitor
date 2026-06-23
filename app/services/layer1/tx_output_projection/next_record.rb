# frozen_string_literal: true

module Layer1
  module TxOutputProjection
    class NextRecord
      def self.call
        Layer1TxOutputProjectionBlock
          .where(
            <<~SQL.squish,
              status = :pending
              OR (status = :failed AND attempts < :max_attempts)
            SQL
            pending: "pending",
            failed: "failed",
            max_attempts: Config.max_attempts
          )
          .order(:height)
          .first
      end
    end
  end
end
