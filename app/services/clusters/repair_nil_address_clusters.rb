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
    end

    def call
      scope = Address.where(cluster_id: nil).where.not(address: [nil, ""])
      scope = scope.limit(@limit) if @limit

      scope.find_in_batches(batch_size: BATCH_SIZE).with_index do |batch, index|
        puts "[repair] batch=#{index + 1} size=#{batch.size}"

        batch.each do |address|
          cluster = Cluster.create!
          address.update!(cluster_id: cluster.id)

          @created_clusters += 1
          @updated += 1
        end

        puts "[repair] updated=#{@updated} created_clusters=#{@created_clusters}"
      end

      {
        ok: true,
        updated: @updated,
        created_clusters: @created_clusters
      }
    end
  end
end
