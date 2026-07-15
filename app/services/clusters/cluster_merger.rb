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

      ApplicationRecord.transaction do
        @address_records = lock_address_records
        cluster_ids = address_records.filter_map(&:cluster_id).uniq.sort

        if cluster_ids.empty?
          create_cluster!
        elsif cluster_ids.size == 1
          attach_unclustered_addresses!(cluster_ids.first)
        else
          merge_clusters!(cluster_ids)
        end
      end
    end

    private

    attr_reader :address_records

    def lock_address_records
      Address
        .where(id: address_records.filter_map(&:id).sort)
        .order(:id)
        .lock
        .to_a
    end

    def lock_clusters(cluster_ids)
      Cluster
        .where(id: Array(cluster_ids).compact.uniq.sort)
        .order(:id)
        .lock
        .to_a
    end

    def create_cluster!
      cluster = Cluster.create!

      Address.where(id: address_records.map(&:id)).update_all(
        cluster_id: cluster.id,
        updated_at: Time.current
      )

      recalculate_cluster!(cluster.id)

      Result.new(
        cluster: cluster,
        created: 1,
        merged: 0,
        source_cluster_ids: [],
        target_cluster_id: cluster.id,
        composition_versions: composition_versions_for([cluster.id])
      )
    end

    def attach_unclustered_addresses!(cluster_id)
      unclustered_ids =
        address_records
          .select { |record| record.cluster_id.nil? }
          .map(&:id)

      cluster = lock_clusters([cluster_id]).first
      changed = 0

      if unclustered_ids.any? && cluster
        changed =
          Address.where(id: unclustered_ids, cluster_id: nil).update_all(
          cluster_id: cluster_id,
          updated_at: Time.current
        )

        if changed.positive?
          increment_composition_version!(cluster)
          recalculate_cluster!(cluster.id)
        end
      end

      Result.new(
        cluster: Cluster.find(cluster_id),
        created: 0,
        merged: 0,
        source_cluster_ids: [],
        target_cluster_id: cluster_id,
        composition_versions: composition_versions_for([cluster_id])
      )
    end

    def merge_clusters!(cluster_ids)
      locked_clusters = lock_clusters(cluster_ids)
      master = locked_clusters.first
      sources = locked_clusters.drop(1)
      source_ids = sources.map(&:id)
      next_version = locked_clusters.map(&:composition_version).max.to_i + 1

      changed =
        Address.where(cluster_id: source_ids).update_all(
          cluster_id: master.id,
          updated_at: Time.current
        )

      unclustered_ids =
        address_records
          .select { |record| record.cluster_id.nil? }
          .map(&:id)

      changed +=
        Address.where(id: unclustered_ids, cluster_id: nil).update_all(
          cluster_id: master.id,
          updated_at: Time.current
        ) if unclustered_ids.any?

      if changed.positive?
        master.update_columns(
          composition_version: next_version,
          updated_at: Time.current
        )
        ([master.id] + source_ids).each do |cluster_id|
          recalculate_cluster!(cluster_id)
        end
      end

      Result.new(
        cluster: Cluster.find(master.id),
        created: 0,
        merged: source_ids.size,
        source_cluster_ids: source_ids,
        target_cluster_id: master.id,
        composition_versions:
          composition_versions_for([master.id] + source_ids)
      )
    end

    def increment_composition_version!(cluster)
      cluster.update_columns(
        composition_version: cluster.composition_version.to_i + 1,
        updated_at: Time.current
      )
    end

    def recalculate_cluster!(cluster_id)
      Cluster.find(cluster_id).recalculate_stats!
    end

    def composition_versions_for(cluster_ids)
      Cluster.where(id: cluster_ids).pluck(:id, :composition_version).to_h
    end

    def empty_result
      Result.new(
        cluster: nil,
        created: 0,
        merged: 0,
        source_cluster_ids: [],
        target_cluster_id: nil,
        composition_versions: {}
      )
    end

    Result = Struct.new(
      :cluster,
      :created,
      :merged,
      :source_cluster_ids,
      :target_cluster_id,
      :composition_versions,
      keyword_init: true
    )
  end
end
