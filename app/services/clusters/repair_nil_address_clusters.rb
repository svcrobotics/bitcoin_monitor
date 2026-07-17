# frozen_string_literal: true

module Clusters
  class RepairNilAddressClusters
    BATCH_SIZE = 1_000

    def self.call(limit: nil)
      new(limit: limit).call
    end

    def initialize(limit: nil)
      @limit = limit&.to_i
      @updated = 0
      @created_clusters = 0
      @marked = 0
      @batches = 0
    end

    def call
      scope =
        Address
          .where(cluster_id: nil)
          .where.not(address: [nil, ""])
          .order(:id)

      scope =
        scope.limit(limit) if limit.present?

      scope.find_in_batches(
        batch_size: BATCH_SIZE
      ) do |batch|
        @batches += 1

        result =
          Clusters::EnsureAddressClusters.call(
            addresses:
              batch.map(&:address)
          )

        @updated +=
          result[:updated].to_i

        @created_clusters +=
          result[:clusters].to_i

        @marked +=
          result[:marked].to_i

        Rails.logger.info(
          "[repair_nil_address_clusters] " \
          "batch=#{@batches} " \
          "updated=#{@updated} " \
          "created_clusters=#{@created_clusters} " \
          "marked=#{@marked}"
        )
      end

      {
        ok: true,
        batches: @batches,
        updated: @updated,
        created_clusters: @created_clusters,
        marked: @marked
      }
    end

    private

    attr_reader :limit

  end
end
