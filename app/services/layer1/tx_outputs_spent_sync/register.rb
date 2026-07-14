# frozen_string_literal: true

module Layer1
  module TxOutputsSpentSync
    class Register
      def self.call(height:, block_hash:)
        new(height: height, block_hash: block_hash).call
      end

      def initialize(height:, block_hash:)
        @height = height.to_i
        @block_hash = block_hash.to_s
      end

      def call
        record = Layer1TxOutputSync.find_or_initialize_by(height: @height)

        if record.new_record? || record.block_hash != @block_hash
          record.assign_attributes(
            block_hash: @block_hash,
            status: "pending",
            inputs_count: 0,
            matching_tx_outputs_count: 0,
            rows_updated: 0,
            remaining_rows: nil,
            attempts: 0,
            duration_ms: nil,
            started_at: nil,
            last_attempt_at: nil,
            completed_at: nil,
            last_error: nil
          )
        end

        record.save!
        record
      end
    end
  end
end
