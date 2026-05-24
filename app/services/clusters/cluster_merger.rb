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
      cluster = Cluster.create!

      Address.where(id: address_records.map(&:id)).update_all(
        cluster_id: cluster.id,
        updated_at: Time.current
      )

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

      # Rebranche toutes les adresses vers le cluster master.
      if other_ids.any?
        Address.where(cluster_id: other_ids).update_all(
          cluster_id: master_id,
          updated_at: Time.current
        )
      end

      # Attache aussi les adresses sans cluster.
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

      # IMPORTANT:
      # Ne pas supprimer les anciens clusters ici.
      #
      # Pourquoi ?
      # - cluster_profiles
      # - cluster_metrics
      # - cluster_signals
      #
      # peuvent encore référencer ces cluster_ids.
      #
      # Le scanner cluster doit rester ultra rapide.
      # Les nettoyages / consolidations analytics seront faits
      # plus tard par des jobs async dédiés.
      #
      # Donc:
      # - PAS de delete_all
      # - PAS de cleanup sync
      # - PAS de recalcul analytics ici

      Result.new(
        cluster: Cluster.find(master_id),
        created: 0,
        merged: other_ids.size
      )
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