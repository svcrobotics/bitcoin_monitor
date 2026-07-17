# frozen_string_literal: true

module Clusters
  class CachedHealthSnapshot
    CACHE_VERSION = 2

    CACHE_KEY =
      "clusters:health_snapshot:v#{CACHE_VERSION}"

    EXPIRES_IN = 30.seconds

    REQUIRED_SOURCE =
      "cluster_strict_health_snapshot"

    class << self
      def read
        cached =
          Rails.cache.read(
            CACHE_KEY
          )

        return cached if valid_snapshot?(
          cached
        )

        refresh!
      end

      def refresh!
        snapshot =
          Clusters::HealthSnapshot.call

        Rails.cache.write(
          CACHE_KEY,
          snapshot,
          expires_in: EXPIRES_IN
        )

        snapshot
      end

      private

      def valid_snapshot?(snapshot)
        return false unless snapshot.is_a?(
          Hash
        )

        return false unless value(
          snapshot,
          :source
        ).to_s == REQUIRED_SOURCE

        %i[
          sync
          counts
          audit
          automation
        ].all? do |key|
          value(
            snapshot,
            key
          ).is_a?(Hash)
        end
      end

      def value(hash, key)
        return hash[key] if hash.key?(
          key
        )

        hash[
          key.to_s
        ]
      end
    end
  end
end
