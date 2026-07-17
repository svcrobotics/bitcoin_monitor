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
        @address_records =
          lock_address_records

        cluster_ids =
          address_records.map(&:cluster_id).compact.uniq

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
      ids =
        address_records
          .map(&:id)
          .compact
          .sort

      Address
        .where(id: ids)
        .order(:id)
        .lock
        .to_a
    end

    def lock_clusters(cluster_ids)
      ids =
        Array(cluster_ids)
          .compact
          .map(&:to_i)
          .uniq
          .sort

      return [] if ids.empty?

      Cluster
        .where(id: ids)
        .order(:id)
        .lock
        .to_a
    end

    def create_cluster!
      cluster = nil

      ApplicationRecord.transaction do
        cluster =
          Cluster.create!(
            composition_version:
              Cluster::INITIAL_COMPOSITION_VERSION
          )

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
        ApplicationRecord.transaction do
          lock_clusters([cluster_id])

          changed =
            Address
              .where(id: unclustered_ids, cluster_id: nil)
              .update_all(
                cluster_id: cluster_id,
                updated_at: Time.current
              )

          if changed.positive?
            advance_composition_version!(
              cluster_id: cluster_id,
              source_cluster_ids: [cluster_id]
            )

            Cluster.find(cluster_id).recalculate_stats!
          end
        end
      end

      Result.new(
        cluster: Cluster.find(cluster_id),
        created: 0,
        merged: 0
      )
    end

    def merge_clusters!(cluster_ids)
      ApplicationRecord.transaction do
        locked_clusters =
          lock_clusters(cluster_ids)

        locked_cluster_ids =
          locked_clusters.map(&:id)

        master_id = locked_cluster_ids.min
        other_ids = locked_cluster_ids - [master_id]

        next_composition_version =
          locked_clusters
            .map(&:composition_version)
            .map(&:to_i)
            .max
            .to_i + 1

        composition_changed = false

        if other_ids.any?
          changed =
            Address.where(cluster_id: other_ids).update_all(
              cluster_id: master_id,
              updated_at: Time.current
            )

          composition_changed ||= changed.positive?

          cleanup_merged_clusters!(other_ids)
        end

        unclustered_ids =
          address_records
            .select { |record| record.cluster_id.nil? }
            .map(&:id)

        if unclustered_ids.any?
          changed =
            Address
              .where(id: unclustered_ids, cluster_id: nil)
              .update_all(
                cluster_id: master_id,
                updated_at: Time.current
              )

          composition_changed ||= changed.positive?
        end

        if composition_changed
          advance_composition_version!(
            cluster_id: master_id,
            next_version: next_composition_version
          )
        end

        Cluster.find(master_id).recalculate_stats!
      end

      Result.new(
        cluster: Cluster.find(cluster_ids.min),
        created: 0,
        merged: cluster_ids.size - 1
      )
    end

    def advance_composition_version!(
      cluster_id:,
      source_cluster_ids: nil,
      next_version: nil
    )
      version =
        next_version ||
        Cluster.next_composition_version_for(
          source_cluster_ids
        )

      Cluster
        .where(id: cluster_id)
        .update_all(
          composition_version: version,
          updated_at: Time.current
        )
    end

    def cleanup_merged_clusters!(cluster_ids)
      ids = Array(cluster_ids).compact
      return if ids.empty?

      ActorBehaviorHeavySnapshot
        .where(
          "cluster_id IN (:ids) OR downstream_cluster_id IN (:ids)",
          ids: ids
        )
        .delete_all

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
