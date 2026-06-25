# frozen_string_literal: true

module Clusters
  module Coverage
    class AddressCursor
      HEIGHT = 0
      BLOCK_HASH = "addresses"
      SOURCE = "addresses"
      PROFILE_VERSION = "address_coverage_v1"

      def self.record
        record =
          ClusterCoverageBlock
            .lock
            .address_coverage
            .first

        record ||=
          ClusterCoverageBlock
            .lock
            .find_or_initialize_by(
              height: HEIGHT
            )

        initialize_record(record) if record.new_record?

        record
      end

      def self.initialize_record(record)
        record.assign_attributes(
          block_hash: BLOCK_HASH,
          status: "pending",
          max_tx_output_id: 0,
          after_tx_output_id: 0,
          expected_outputs_count: 0,
          processed_outputs_count: 0,
          expected_address_outputs_count: 0,
          processed_address_outputs_count: 0,
          scripts_without_address_count: 0,
          addresses_created_count: 0,
          singleton_clusters_created_count: 0,
          pages_processed: 0,
          attempts: 0,
          started_at: nil,
          completed_at: nil,
          last_error: nil,
          metadata: base_metadata
        )
      end

      def self.base_metadata
        {
          "source" => SOURCE,
          "profile_version" => PROFILE_VERSION,
          "cursor_source" => "addresses",
          "last_processed_address_id" => "0",
          "high_watermark_address_id" => "0"
        }
      end
    end
  end
end
