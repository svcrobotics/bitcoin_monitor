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
      return empty_result if address_records.empty?

      cluster_ids = address_records.map(&:cluster_id).compact.uniq

      if cluster_ids.empty?
        create_cluster!
      elsif cluster_ids.size == 1
        attach_unclustered_addresses!(cluster_ids.first)
      else
        merge_clusters!(cluster_ids)
      end
    end

    private

    attr_reader :address_records

    def create_cluster!
      cluster = nil

      ApplicationRecord.transaction do
        cluster = Cluster.create!

        Address.where(id: address_records.map(&:id)).update_all(
          cluster_id: cluster.id,
          updated_at: Time.current
        )

        cluster.recalculate_stats!
      end

      Result.new(
        cluster: cluster,
        created: 1,
        merged: 0
      )
    end

    def attach_unclustered_addresses!(cluster_id)
      unclustered_ids =
        address_records
          .select { |record| record.cluster_id.nil? }
          .map(&:id)

      if unclustered_ids.any?
        Address.where(id: unclustered_ids).update_all(
          cluster_id: cluster_id,
          updated_at: Time.current
        )
      end

      Result.new(
        cluster: Cluster.find(cluster_id),
        created: 0,
        merged: 0
      )
    end

    def merge_clusters!(cluster_ids)
      master_id = cluster_ids.min
      other_ids = cluster_ids - [master_id]

      ApplicationRecord.transaction do
        if other_ids.any?
          Address.where(cluster_id: other_ids).update_all(
            cluster_id: master_id,
            updated_at: Time.current
          )

          cleanup_merged_clusters!(other_ids)
        end

        unclustered_ids =
          address_records
            .select { |record| record.cluster_id.nil? }
            .map(&:id)

        if unclustered_ids.any?
          Address.where(id: unclustered_ids).update_all(
            cluster_id: master_id,
            updated_at: Time.current
          )
        end

        Cluster.find(master_id).recalculate_stats!
      end

      Result.new(
        cluster: Cluster.find(master_id),
        created: 0,
        merged: other_ids.size
      )
    end

    def cleanup_merged_clusters!(cluster_ids)
      ids = Array(cluster_ids).compact
      return if ids.empty?

      ActorProfileDelta.where(cluster_id: ids).delete_all
      ActorLabel.where(cluster_id: ids).delete_all
      ActorProfile.where(cluster_id: ids).delete_all
      ClusterActivityState.where(cluster_id: ids).delete_all

      Cluster.where(id: ids).delete_all
    end

    def empty_result
      Result.new(
        cluster: nil,
        created: 0,
        merged: 0
      )
    end

    Result = Struct.new(
      :cluster,
      :created,
      :merged,
      keyword_init: true
    )
  end
end