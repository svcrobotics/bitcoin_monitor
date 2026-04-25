# frozen_string_literal: true

module Clusters
  class ClusterMerger
    def self.call(address_records:)
      new(address_records: address_records).call
    end

    def initialize(address_records:)
      @address_records = Array(address_records).compact
    end

    def call
      cluster_ids = address_records.map(&:cluster_id).compact.uniq

      if cluster_ids.empty?
        return create_cluster!
      end

      if cluster_ids.size == 1
        return attach_unclustered_addresses!(Cluster.find(cluster_ids.first))
      end

      merge_clusters!(cluster_ids)
    end

    private

    attr_reader :address_records

    def create_cluster!
      cluster = Cluster.create!

      Address.where(id: address_records.map(&:id)).update_all(
        cluster_id: cluster.id,
        updated_at: Time.current
      )

      Result.new(cluster: cluster, created: 1, merged: 0)
    end

    def attach_unclustered_addresses!(cluster)
      unclustered_ids = address_records.select { |record| record.cluster_id.nil? }.map(&:id)

      if unclustered_ids.any?
        Address.where(id: unclustered_ids).update_all(
          cluster_id: cluster.id,
          updated_at: Time.current
        )
      end

      Result.new(cluster: cluster, created: 0, merged: 0)
    end

    def merge_clusters!(cluster_ids)
      master_id = cluster_ids.min
      other_ids = cluster_ids - [master_id]

      Address.where(cluster_id: other_ids).update_all(
        cluster_id: master_id,
        updated_at: Time.current
      )

      unclustered_ids = address_records.select { |record| record.cluster_id.nil? }.map(&:id)

      if unclustered_ids.any?
        Address.where(id: unclustered_ids).update_all(
          cluster_id: master_id,
          updated_at: Time.current
        )
      end

      cleanup_derived_rows_for_clusters!([master_id] + other_ids)

      Cluster.where(id: other_ids).delete_all

      Result.new(
        cluster: Cluster.find(master_id),
        created: 0,
        merged: other_ids.size
      )
    end

    def cleanup_derived_rows_for_clusters!(cluster_ids)
      ids = Array(cluster_ids).compact.uniq
      return if ids.empty?

      ClusterSignal.where(cluster_id: ids).delete_all
      ClusterMetric.where(cluster_id: ids).delete_all
      ClusterProfile.where(cluster_id: ids).delete_all
    end

    Result = Struct.new(:cluster, :created, :merged, keyword_init: true)
  end
end
