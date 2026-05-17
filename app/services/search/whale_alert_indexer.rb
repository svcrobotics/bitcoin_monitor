# frozen_string_literal: true

module Search
  class WhaleAlertIndexer
    INDEX_NAME = Search::IndexManager::INDEX_NAME

    def self.call(limit: 1_000)
      new(limit: limit).call
    end

    def initialize(limit:)
      @limit = limit.to_i
    end

    def call
      alerts.find_each do |alert|
        ELASTICSEARCH_CLIENT.index(
          index: INDEX_NAME,
          id: "whale_alert_#{alert.id}",
          body: {
            type: "whale_alert",
            title: "Whale alert",
            subtitle: subtitle(alert),
            body: body(alert),
            route: "/whale_alerts",
            score: score(alert),
            amount_btc: amount_btc(alert),
            indexed_at: Time.current
          }
        )
      end

      ELASTICSEARCH_CLIENT.indices.refresh(index: INDEX_NAME)

      { ok: true, indexed: alerts.count }
    end

    private

    attr_reader :limit

    def alerts
      WhaleAlert
        .order(created_at: :desc)
        .limit(limit)
    end

    def subtitle(alert)
      [
        "#{amount_btc(alert).round(4)} BTC",
        ("block #{alert.block_height}" if alert.respond_to?(:block_height)),
        ("tx #{alert.txid}" if alert.respond_to?(:txid))
      ].compact.join(" · ")
    end

    def body(alert)
      [
        "whale",
        "whale alert",
        "large transfer",
        "gros mouvement",
        "#{amount_btc(alert).round(4)} BTC",
        (alert.txid if alert.respond_to?(:txid)),
        ("block #{alert.block_height}" if alert.respond_to?(:block_height)),
        alert.try(:tier),
        alert.try(:source)
      ].compact.join(" ")
    end

    def amount_btc(alert)
      if alert.respond_to?(:amount_btc)
        alert.amount_btc.to_f
      elsif alert.respond_to?(:total_out_btc)
        alert.total_out_btc.to_f
      elsif alert.respond_to?(:total_output_btc)
        alert.total_output_btc.to_f
      else
        0.0
      end
    end

    def score(alert)
      btc = amount_btc(alert)

      if btc >= 1_000
        100
      elsif btc >= 500
        80
      elsif btc >= 100
        60
      else
        40
      end
    end
  end
end
