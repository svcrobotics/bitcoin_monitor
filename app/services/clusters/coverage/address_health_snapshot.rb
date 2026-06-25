# frozen_string_literal: true

module Clusters
  module Coverage
    class AddressHealthSnapshot
      def self.call
        new.call
      end

      def call
        cursor =
          ClusterCoverageBlock
            .address_coverage
            .first

        last_processed_address_id =
          cursor&.after_tx_output_id.to_i

        current_max_address_id =
          Address.maximum(:id).to_i

        {
          last_processed_address_id: last_processed_address_id,
          current_max_address_id: current_max_address_id,
          address_id_lag:
            [
              current_max_address_id - last_processed_address_id,
              0
            ].max,
          high_watermark_address_id:
            cursor&.max_tx_output_id.to_i,
          null_addresses_up_to_cursor:
            null_addresses_up_to_cursor(last_processed_address_id),
          null_addresses_after_cursor:
            null_addresses_after_cursor(last_processed_address_id),
          oldest_null_address_id:
            oldest_null_address_id,
          status:
            cursor&.status || "missing",
          last_error:
            cursor&.last_error,
          last_completed_at:
            cursor&.completed_at
        }
      end

      private

      def null_addresses_up_to_cursor(last_processed_address_id)
        return 0 unless last_processed_address_id.positive?

        null_address_scope
          .where(
            "id <= ?",
            last_processed_address_id
          )
          .count
      end

      def null_addresses_after_cursor(last_processed_address_id)
        null_address_scope
          .where(
            "id > ?",
            last_processed_address_id
          )
          .count
      end

      def oldest_null_address_id
        null_address_scope
          .minimum(:id)
      end

      def null_address_scope
        Address
          .where(cluster_id: nil)
          .where.not(address: [nil, ""])
      end
    end
  end
end
