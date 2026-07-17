# frozen_string_literal: true

module Search
  class ModuleIndexer
    INDEX_NAME = Search::IndexManager::INDEX_NAME

    MODULES = [
      {
        id: "module_btc_dashboard",
        type: "module",
        title: "BTC Dashboard",
        subtitle: "Marché Bitcoin",
        body: "bitcoin btc prix candles ma200 ath drawdown market marché tendance",
        route: "/btc/dashboard"
      },
      {
        id: "module_cluster_events",
        type: "module",
        title: "Cluster Events",
        subtitle: "Alertes cluster temps réel",
        body: "cluster events clickhouse whale outflow large outflow graph intelligence realtime alertes",
        route: "/clusters/events"
      },
      {
        id: "module_exchange_flows",
        type: "module",
        title: "Exchange Flows",
        subtitle: "Inflow Outflow",
        body: "exchange inflow outflow netflow plateformes liquidité flux entrants sortants",
        route: "/actors/exchange_core_flows"
      },
      {
        id: "module_whale_alerts",
        type: "module",
        title: "Whale Alerts",
        subtitle: "Gros mouvements BTC",
        body: "whale bitcoin btc transaction large transfer gros mouvement alerte baleine",
        route: "/whale_alerts"
      },
      {
        id: "module_clusters",
        type: "module",
        title: "Clusters",
        subtitle: "Entités et relations on-chain",
        body: "cluster graph entités adresses relations multi input address links",
        route: "/clusters"
      },
      {
        id: "module_cluster_signals",
        type: "module",
        title: "Cluster Signals",
        subtitle: "Signaux analytiques cluster",
        body: "cluster signals metrics activity spike sudden activity analytics score",
        route: "/cluster_signals"
      },    ].freeze

    def self.call
      MODULES.each do |doc|
        ELASTICSEARCH_CLIENT.index(
          index: INDEX_NAME,
          id: doc[:id],
          body: doc.merge(indexed_at: Time.current)
        )
      end

      ELASTICSEARCH_CLIENT.indices.refresh(index: INDEX_NAME)

      { ok: true, indexed: MODULES.size }
    end
  end
end