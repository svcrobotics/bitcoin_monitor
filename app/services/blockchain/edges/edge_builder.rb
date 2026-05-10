# frozen_string_literal: true

module Blockchain
  module Edges
    class EdgeBuilder
      MAX_ADDRESSES_PER_TX = 20

      def initialize(logger: Rails.logger)
        @logger = logger
      end

      def call(payload)
        addresses = payload[:addresses] || payload["addresses"]
        addresses = addresses.to_a.compact.uniq

        return if addresses.size < 2

        if addresses.size > MAX_ADDRESSES_PER_TX
          @logger.info(
            "[edge_builder] skipped txid=#{payload[:txid] || payload['txid']} " \
            "addresses=#{addresses.size} reason=too_many_addresses"
          )
          return
        end

        rows = pairs(addresses).map do |address_a, address_b|
          build_row(payload, address_a, address_b)
        end

        Edge.insert_all(rows, unique_by: :index_edges_unique_triplet) if rows.any?
      rescue StandardError => e
        @logger.error("[edge_builder] error #{e.class}: #{e.message}")
      end

      private

      def pairs(addresses)
        addresses.combination(2)
      end

      def build_row(payload, a, b)
        address_a, address_b = [a, b].sort
        now = Time.current

        {
          txid: payload[:txid] || payload["txid"],
          address_a: address_a,
          address_b: address_b,
          block_height: payload[:block_height] || payload["block_height"],
          block_hash: payload[:block_hash] || payload["block_hash"],
          block_time: normalize_time(payload[:block_time] || payload["block_time"]),
          created_at: now,
          updated_at: now
        }
      end

      def normalize_time(value)
        return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
        return Time.zone.parse(value) if value.is_a?(String)
        return Time.at(value).in_time_zone if value.present?

        nil
      end
    end
  end
end