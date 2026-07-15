# frozen_string_literal: true

module Clusters
  class ActorProfileHandoffRegister
    class CompositionChanged < StandardError; end

    def self.call(cluster_height:, block_hash:, clusters_touched:)
      new(
        cluster_height: cluster_height,
        block_hash: block_hash,
        clusters_touched: clusters_touched
      ).call
    end

    def initialize(cluster_height:, block_hash:, clusters_touched:)
      @cluster_height = Integer(cluster_height)
      @block_hash = block_hash.to_s
      @clusters_touched = normalize_clusters(clusters_touched)
    end

    def call
      return empty_result if @clusters_touched.empty?

      verify_persisted_versions!
      now = Time.current
      inserted = ClusterActorProfileHandoff.insert_all(
        @clusters_touched.map do |cluster|
          {
            cluster_height: @cluster_height,
            block_hash: @block_hash,
            cluster_id: cluster.fetch(:cluster_id),
            composition_version: cluster.fetch(:composition_version),
            status: "pending",
            attempts: 0,
            created_at: now,
            updated_at: now
          }
        end,
        unique_by: :idx_cluster_actor_handoffs_certification_version,
        returning: %w[id]
      )

      {
        registered: inserted.rows.size,
        handoffs: persisted_handoffs
      }
    end

    private

    def normalize_clusters(clusters)
      Array(clusters).map do |cluster|
        values = cluster.respond_to?(:symbolize_keys) ? cluster.symbolize_keys : cluster
        {
          cluster_id: Integer(values.fetch(:cluster_id)),
          composition_version: Integer(values.fetch(:composition_version))
        }
      end.uniq.sort_by { |cluster| [cluster.fetch(:cluster_id), cluster.fetch(:composition_version)] }
    end

    def verify_persisted_versions!
      expected = @clusters_touched.to_h do |cluster|
        [cluster.fetch(:cluster_id), cluster.fetch(:composition_version)]
      end
      actual = Cluster.where(id: expected.keys).pluck(:id, :composition_version).to_h
      return if actual == expected

      raise CompositionChanged,
        "Cluster composition changed before ActorProfile handoff registration"
    end

    def persisted_handoffs
      pairs = @clusters_touched.map do |cluster|
        [cluster.fetch(:cluster_id), cluster.fetch(:composition_version)]
      end
      ClusterActorProfileHandoff
        .where(cluster_height: @cluster_height, block_hash: @block_hash)
        .where(cluster_id: pairs.map(&:first))
        .order(:cluster_id, :composition_version, :id)
        .filter_map do |handoff|
          pair = [handoff.cluster_id, handoff.composition_version]
          next unless pairs.include?(pair)

          {
            id: handoff.id,
            cluster_id: handoff.cluster_id,
            composition_version: handoff.composition_version,
            status: handoff.status
          }
        end
    end

    def empty_result
      { registered: 0, handoffs: [] }
    end
  end
end
