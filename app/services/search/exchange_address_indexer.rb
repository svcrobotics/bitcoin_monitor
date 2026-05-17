# frozen_string_literal: true

module Search
  class ExchangeAddressIndexer
    INDEX_NAME = Search::IndexManager::INDEX_NAME

    def self.call(limit: 5_000)
      new(limit: limit).call
    end

    def initialize(limit:)
      @limit = limit.to_i
    end

    def call
      addresses.find_each do |record|
        ELASTICSEARCH_CLIENT.index(
          index: INDEX_NAME,
          id: "exchange_address_#{record.id}",
          body: document_body(record)
        )
      end

      ELASTICSEARCH_CLIENT.indices.refresh(index: INDEX_NAME)

      { ok: true, indexed: addresses.count }
    end

    private

    attr_reader :limit

    def addresses
      ExchangeAddress
        .order(updated_at: :desc)
        .limit(limit)
    end

    def document_body(record)
      {
        type: "exchange_address",
        title: "Exchange-like address",
        subtitle: record.address,
        body: [
          "exchange",
          "exchange like",
          "exchange-like",
          "address",
          record.address,
          record.source,
          record.confidence,
          "occurrences #{record.occurrences}",
          "first seen #{record.first_seen_at}",
          "last seen #{record.last_seen_at}"
        ].compact.join(" "),
        route: "/exchange_like",
        address: record.address,
        score: confidence_score(record),
        source: record.source,
        indexed_at: Time.current
      }
    end

    def confidence_score(record)
      value = record.confidence

      if value.respond_to?(:to_f)
        (value.to_f * 100).clamp(0, 100).to_i
      else
        0
      end
    end
  end
end
