# frozen_string_literal: true

module Search
  class GlobalSearch
    INDEX_NAME = Search::IndexManager::INDEX_NAME

    def self.call(query:, limit: 10)
      new(query: query, limit: limit).call
    end

    def initialize(query:, limit:)
      @query = query.to_s.strip
      @limit = limit.to_i
    end

    def call
      return [] if query.blank?

      response = ELASTICSEARCH_CLIENT.search(
        index: INDEX_NAME,
        body: {
          size: limit,
          query: {
            multi_match: {
              query: query,
              fields: [
                "title^4",
                "subtitle^2",
                "body",
                "address^5",
                "txid^5"
              ],
              fuzziness: "AUTO"
            }
          }
        }
      )

      response.dig("hits", "hits").to_a.map do |hit|
        source = hit["_source"] || {}

        {
          id: hit["_id"],
          score: hit["_score"],
          type: source["type"],
          title: source["title"],
          subtitle: source["subtitle"],
          route: source["route"],
          source: source
        }
      end
    end

    private

    attr_reader :query, :limit
  end
end
