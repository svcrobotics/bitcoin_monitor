# frozen_string_literal: true

require "json"

module Search
  class ClusterEventIndexer
    INDEX_NAME = Search::IndexManager::INDEX_NAME

    def self.call(limit: 500)
      new(limit: limit).call
    end

    def initialize(limit:)
      @limit = limit.to_i
    end

    def call
      events.each do |event|
        ELASTICSEARCH_CLIENT.index(
          index: INDEX_NAME,
          id: document_id(event),
          body: document_body(event)
        )
      end

      ELASTICSEARCH_CLIENT.indices.refresh(index: INDEX_NAME)

      { ok: true, indexed: events.size }
    end

    private

    attr_reader :limit

    def events
      @events ||= Clusters::ClickHouseEventReader.recent(limit: limit)
    end

    def document_id(event)
      [
        "cluster_event",
        event["event_time"].to_s.parameterize,
        event["cluster_id"],
        event["signal_type"],
        event["score"]
      ].join("_")
    end

    def document_body(event)
      signal_type = event["signal_type"].to_s
      signal_words = signal_type.tr("_", " ")
      cluster_id = event["cluster_id"].to_i
      amount_btc = event["amount_btc"].to_f

      {
        type: "cluster_event",
        title: title_for(signal_type),
        subtitle: "Cluster ##{cluster_id} · score #{event["score"]}",
        body: [
          signal_type,
          signal_words,
          title_for(signal_type),
          event["severity"],
          event["source"],
          "cluster #{cluster_id}",
          "block #{event["block_height"]}",
          amount_btc.positive? ? "#{amount_btc.round(4)} BTC" : nil,
          "tx #{event["tx_count"]}",
          "addresses #{event["address_count"]}"
        ].compact.join(" "),
        route: "/clusters/events",
        cluster_id: cluster_id,
        score: event["score"].to_i,
        amount_btc: amount_btc,
        severity: event["severity"],
        source: event["source"],
        indexed_at: Time.current
      }
    end

    def title_for(signal_type)
      if signal_type == "large_outflow"
        "Gros mouvement sortant"
      elsif signal_type == "whale_cluster_activity"
        "Activité whale"
      elsif signal_type == "activity_spike"
        "Pic d’activité cluster"
      elsif signal_type == "large_link_creation"
        "Expansion du graphe"
      elsif signal_type == "cluster_merge"
        "Fusion de clusters"
      elsif signal_type == "cluster_reactivation"
        "Cluster ancien actif"
      else
        signal_type.humanize
      end
    end
  end
end
