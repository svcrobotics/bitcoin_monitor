# frozen_string_literal: true

module Search
  class IndexManager
    INDEX_NAME = "bitcoin_monitor_global"

    def self.create!
      client = ELASTICSEARCH_CLIENT

      client.indices.delete(index: INDEX_NAME) if client.indices.exists?(index: INDEX_NAME)

      client.indices.create(
        index: INDEX_NAME,
        body: {
          mappings: {
            properties: {
              type: { type: "keyword" },
              title: { type: "text" },
              subtitle: { type: "text" },
              body: { type: "text" },
              route: { type: "keyword" },
              cluster_id: { type: "integer" },
              address: { type: "keyword" },
              txid: { type: "keyword" },
              score: { type: "integer" },
              amount_btc: { type: "double" },
              severity: { type: "keyword" },
              source: { type: "keyword" },
              indexed_at: { type: "date" }
            }
          }
        }
      )
    end
  end
end
