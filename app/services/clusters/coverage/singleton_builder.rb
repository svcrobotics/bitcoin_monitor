# frozen_string_literal: true

module Clusters
  module Coverage
    class SingletonBuilder
      DEFAULT_BATCH_SIZE = 1_000

      def self.call(
        batch_size: DEFAULT_BATCH_SIZE,
        after_id: nil
      )
        new(
          batch_size: batch_size,
          after_id: after_id
        ).call
      end

      def initialize(
        batch_size: DEFAULT_BATCH_SIZE,
        after_id: nil
      )
        @batch_size =
          [
            batch_size.to_i,
            1
          ].max

        @after_id = after_id&.to_i
      end

      def call
        rows =
          load_rows

        valid_addresses =
          rows
            .map(&:second)
            .select do |address|
              Clusters::Coverage::BitcoinAddressValidator
                .valid_bitcoin_address?(address)
            end

        invalid_addresses_count =
          rows.size - valid_addresses.size

        ensure_result =
          if valid_addresses.empty?
            empty_ensure_result
          else
            Clusters::EnsureAddressClusters.call(
              addresses: valid_addresses
            )
          end

        updated =
          ensure_result[:updated].to_i

        {
          ok: true,
          scanned: rows.size,
          valid_addresses: valid_addresses.size,
          invalid_addresses: invalid_addresses_count,
          updated: updated,
          singleton_clusters_created:
            ensure_result[:clusters].to_i,
          ignored_already_clustered:
            valid_addresses.size - updated,
          last_address_id:
            rows.last&.first
        }
      end

      private

      attr_reader :batch_size, :after_id

      def load_rows
        scope =
          Address
            .where(cluster_id: nil)
            .where.not(address: [nil, ""])

        if after_id.present?
          scope =
            scope.where(
              "id > ?",
              after_id
            )
        end

        scope
          .order(:id)
          .limit(batch_size)
          .pluck(:id, :address)
      end

      def empty_ensure_result
        {
          ok: true,
          updated: 0,
          clusters: 0,
          marked: 0
        }
      end

    end
  end
end
