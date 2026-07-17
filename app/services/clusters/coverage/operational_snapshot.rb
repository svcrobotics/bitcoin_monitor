# frozen_string_literal: true

require "json"

module Clusters
  module Coverage
    class OperationalSnapshot
      CACHE_KEY =
        "cluster_coverage:operational_snapshot"

      CACHE_TTL_SECONDS = 600

      def self.refresh(from_height:, to_height:)
        new(
          from_height: from_height,
          to_height: to_height
        ).refresh
      end

      def self.read
        raw =
          Sidekiq.redis do |redis|
            redis.get(CACHE_KEY)
          end

        return unavailable unless raw.present?

        JSON.parse(
          raw,
          symbolize_names: true
        )
      rescue StandardError => error
        Rails.logger.warn(
          "[cluster_coverage_operational] " \
          "read_failed " \
          "#{error.class}: #{error.message}"
        )

        unavailable(
          error:
            "#{error.class}: #{error.message}"
        )
      end

      def self.unavailable(error: nil)
        {
          status: "unknown",
          complete: false,
          missing_addresses: nil,
          unclustered_addresses: nil,
          invalid_cluster_refs: nil,
          address_cursor_lag: nil,
          checked_from_height: nil,
          checked_to_height: nil,
          checked_at: nil,
          error: error
        }
      end

      def initialize(from_height:, to_height:)
        @from_height = from_height.to_i
        @to_height = to_height.to_i
      end

      def refresh
        raise(
          ArgumentError,
          "from_height must be positive"
        ) unless from_height.positive?

        raise(
          ArgumentError,
          "to_height must be >= from_height"
        ) if to_height < from_height

        health =
          Clusters::Coverage::
            AddressHealthSnapshot.call

        scope =
          ClusterInput
            .where(
              spent_block_height:
                from_height..to_height
            )
            .where.not(
              address: [nil, ""]
            )

        missing_addresses =
          scope
            .joins(
              "LEFT JOIN addresses " \
              "ON addresses.address = " \
              "cluster_inputs.address"
            )
            .where(
              addresses: { id: nil }
            )
            .distinct
            .count(:address)

        invalid_cluster_refs =
          scope
            .joins(
              "INNER JOIN addresses " \
              "ON addresses.address = " \
              "cluster_inputs.address"
            )
            .joins(
              "LEFT JOIN clusters " \
              "ON clusters.id = " \
              "addresses.cluster_id"
            )
            .where.not(
              addresses: {
                cluster_id: nil
              }
            )
            .where(
              clusters: { id: nil }
            )
            .distinct
            .count("addresses.id")

        unclustered_addresses =
          health[
            :null_addresses_up_to_cursor
          ].to_i +
          health[
            :null_addresses_after_cursor
          ].to_i

        address_cursor_lag =
          health[:address_id_lag].to_i

        complete =
          health[:status].to_s ==
            "completed" &&
          address_cursor_lag.zero? &&
          missing_addresses.zero? &&
          unclustered_addresses.zero? &&
          invalid_cluster_refs.zero?

        snapshot = {
          status:
            complete ?
              "complete" :
              "incomplete",

          complete: complete,

          missing_addresses:
            missing_addresses,

          unclustered_addresses:
            unclustered_addresses,

          invalid_cluster_refs:
            invalid_cluster_refs,

          address_cursor_lag:
            address_cursor_lag,

          checked_from_height:
            from_height,

          checked_to_height:
            to_height,

          checked_at:
            Time.current.iso8601(6)
        }

        Sidekiq.redis do |redis|
          redis.set(
            CACHE_KEY,
            JSON.generate(snapshot),
            ex: CACHE_TTL_SECONDS
          )
        end

        snapshot
      end

      private

      attr_reader(
        :from_height,
        :to_height
      )
    end
  end
end
