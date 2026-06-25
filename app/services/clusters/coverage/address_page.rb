# frozen_string_literal: true

require "set"

module Clusters
  module Coverage
    class AddressPage
      DEFAULT_BATCH_SIZE = 500

      def self.call(
        after_id:,
        high_watermark:,
        batch_size: DEFAULT_BATCH_SIZE,
        reconcile: false
      )
        new(
          after_id: after_id,
          high_watermark: high_watermark,
          batch_size: batch_size,
          reconcile: reconcile
        ).call
      end

      def initialize(
        after_id:,
        high_watermark:,
        batch_size: DEFAULT_BATCH_SIZE,
        reconcile: false
      )
        @after_id = after_id.to_i
        @high_watermark = high_watermark.to_i
        @batch_size = [batch_size.to_i, 1].max
        @reconcile = reconcile == true
      end

      def call
        rows = load_rows

        valid_unclustered =
          rows
            .select { |row| row[:cluster_id].nil? }
            .select do |row|
              Clusters::Coverage::BitcoinAddressValidator
                .valid_bitcoin_address?(row[:address])
            end

        pending_strict_addresses =
          pending_strict_cluster_input_addresses(
            valid_unclustered.map { |row| row[:address] }
          )

        clusterable_addresses =
          valid_unclustered
            .reject do |row|
              pending_strict_addresses.include?(
                row[:address]
              )
            end

        ensure_result =
          if clusterable_addresses.empty?
            empty_ensure_result
          else
            Clusters::EnsureAddressClusters.call(
              addresses:
                clusterable_addresses.map { |row| row[:address] },
              mark_dirty: false
            )
          end

        {
          ok: true,
          scanned: rows.size,
          valid_addresses: valid_unclustered.size,
          invalid_addresses: invalid_unclustered_count(rows),
          already_clustered: rows.count { |row| row[:cluster_id].present? },
          skipped_pending_cluster_inputs:
            pending_strict_addresses.size,
          updated: ensure_result[:updated].to_i,
          singleton_clusters_created: ensure_result[:clusters].to_i,
          ignored_already_clustered:
            clusterable_addresses.size - ensure_result[:updated].to_i,
          first_address_id: rows.first&.fetch(:id),
          last_address_id: rows.last&.fetch(:id)
        }
      end

      private

      attr_reader(
        :after_id,
        :high_watermark,
        :batch_size,
        :reconcile
      )

      def load_rows
        scope =
          Address
            .where.not(address: [nil, ""])
            .order(:id)
            .limit(batch_size)

        scope =
          if reconcile
            scope
              .where(cluster_id: nil)
              .where("id <= ?", high_watermark)
              .where("id > ?", after_id)
          else
            scope
              .where("id > ?", after_id)
              .where("id <= ?", high_watermark)
          end

        scope
          .pluck(:id, :address, :cluster_id)
          .map do |id, address, cluster_id|
            {
              id: id,
              address: address,
              cluster_id: cluster_id
            }
          end
      end

      def invalid_unclustered_count(rows)
        rows.count do |row|
          row[:cluster_id].nil? &&
            !Clusters::Coverage::BitcoinAddressValidator
              .valid_bitcoin_address?(row[:address])
        end
      end

      def pending_strict_cluster_input_addresses(addresses)
        values =
          Array(addresses)
            .compact_blank
            .uniq

        return Set.new if values.empty?

        ClusterInput
          .where(address: values)
          .where(cluster_processed_at: nil)
          .distinct
          .pluck(:address)
          .to_set
      end

      def empty_ensure_result
        {
          ok: true,
          updated: 0,
          clusters: 0
        }
      end
    end
  end
end
