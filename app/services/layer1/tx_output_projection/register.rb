# frozen_string_literal: true

module Layer1
  module TxOutputProjection
    class Register
      def self.call(
        height:,
        block_hash:,
        expected_outputs_count: nil,
        expected_outputs_value_btc: nil
      )
        new(
          height: height,
          block_hash: block_hash,
          expected_outputs_count: expected_outputs_count,
          expected_outputs_value_btc: expected_outputs_value_btc
        ).call
      end

      def initialize(
        height:,
        block_hash:,
        expected_outputs_count:,
        expected_outputs_value_btc:
      )
        @height = height.to_i
        @block_hash = block_hash.to_s
        @expected_outputs_count = expected_outputs_count
        @expected_outputs_value_btc = expected_outputs_value_btc
      end

      def call
        record = Layer1TxOutputProjectionBlock.find_or_initialize_by(
          height: @height
        )

        if record.new_record? || record.block_hash != @block_hash
          record.assign_attributes(
            block_hash: @block_hash,
            status: "pending",
            expected_outputs_count: expected_outputs_count,
            expected_outputs_value_btc: expected_outputs_value_btc,
            projected_outputs_count: 0,
            projected_outputs_value_btc: BigDecimal("0"),
            rows_inserted: 0,
            rows_skipped: 0,
            attempts: 0,
            duration_ms: nil,
            started_at: nil,
            last_attempt_at: nil,
            completed_at: nil,
            last_error: nil,
            metadata: {}
          )
        elsif record.status == "processing"
          record.status = "pending"
        end

        record.save!
        record
      end

      private

      def expected_outputs_count
        return @expected_outputs_count.to_i unless @expected_outputs_count.nil?

        strict_output_facts.fetch(:outputs_count)
      end

      def expected_outputs_value_btc
        return BigDecimal(@expected_outputs_value_btc.to_s) unless @expected_outputs_value_btc.nil?

        strict_output_facts.fetch(:outputs_value_btc)
      end

      def strict_output_facts
        @strict_output_facts ||= Layer1::StrictOutputFacts.call(height: @height)
      end
    end
  end
end
