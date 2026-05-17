# frozen_string_literal: true

module Search
  class ClusterIndexer
    INDEX_NAME = Search::IndexManager::INDEX_NAME

    def self.call(limit: 1_000)
      new(limit: limit).call
    end

    def initialize(limit:)
      @limit = limit.to_i
    end

    def call
      clusters.find_each do |cluster|
        profile = cluster.cluster_profile

        ELASTICSEARCH_CLIENT.index(
          index: INDEX_NAME,
          id: "cluster_#{cluster.id}",
          body: {
            type: "cluster",
            title: "Cluster ##{cluster.id}",
            subtitle: subtitle(profile),
            body: body(cluster, profile),
            route: "/clusters/#{cluster.id}",
            cluster_id: cluster.id,
            score: profile&.score.to_i,
            indexed_at: Time.current
          }
        )
      end

      ELASTICSEARCH_CLIENT.indices.refresh(index: INDEX_NAME)

      { ok: true, indexed: clusters.count }
    end

    private

    attr_reader :limit

    def clusters
      Cluster
        .includes(:cluster_profile)
        .order(updated_at: :desc)
        .limit(limit)
    end

    def subtitle(profile)
      return "Cluster Bitcoin" unless profile

      [
        profile.classification.presence,
        "#{profile.cluster_size.to_i} adresses",
        "#{profile.tx_count.to_i} tx"
      ].compact.join(" · ")
    end

    def body(cluster, profile)
      return "cluster bitcoin address graph entity" unless profile

      [
        "cluster",
        "cluster #{cluster.id}",
        "entity",
        "graph",
        profile.classification,
        profile.traits,
        "#{profile.cluster_size.to_i} addresses",
        "#{profile.tx_count.to_i} transactions",
        "#{profile.total_sent_sats.to_f / 100_000_000} BTC sent"
      ].compact.join(" ")
    end
  end
end
