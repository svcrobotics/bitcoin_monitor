# frozen_string_literal: true

module Codebase
  class Searcher
    DEFAULT_LIMIT = 8
    CANDIDATE_LIMIT = 30

    BOOST_PATHS = [
      "app/services/blockchain/",
      "app/jobs/blockchain/",
      "app/services/layer1/",
      "app/jobs/layer1/",
      "app/services/realtime/",
      "app/jobs/realtime/",
      "app/services/clusters/",
      "app/jobs/clusters/"
    ].freeze

    PENALTY_PATHS = [
      "app/views/",
      "app/helpers/",
      "app/javascript/",
      "app/services/intelligence/",
      "app/views/intelligence/"
    ].freeze

    def self.call(query, limit: DEFAULT_LIMIT)
      new(query, limit: limit).call
    end

    def initialize(query, limit:)
      @query = query.to_s
      @normalized = @query.downcase
      @limit = limit
    end

    def call
      query_embedding = Ai::Embedding.call(@query)

      candidates =
        CodeChunk
          .nearest_neighbors(:embedding, query_embedding, distance: "cosine")
          .first(CANDIDATE_LIMIT)

      rerank(candidates).first(@limit)
    end

    private

    def rerank(chunks)
      chunks
        .map { |chunk| [chunk, score(chunk)] }
        .sort_by { |_chunk, score| -score }
        .map(&:first)
    end

    def score(chunk)
      score = 0
      path = chunk.path.to_s.downcase
      content = chunk.content.to_s.downcase

      BOOST_PATHS.each do |prefix|
        score += 5 if path.start_with?(prefix)
      end

      PENALTY_PATHS.each do |prefix|
        score -= 6 if path.start_with?(prefix)
      end

      extracted_terms.each do |term|
        score += 3 if path.include?(term)
        score += 1 if content.include?(term)
      end

      if architecture_question?
        score += 4 if path.include?("blockchain/")
        score += 3 if path.include?("processing")
        score += 3 if path.include?("ingest")
        score += 3 if path.include?("flushers")
        score += 2 if path.include?("utxo")
        score += 2 if path.include?("cluster")
        score -= 5 if path.include?("intelligence/")
        score -= 5 if path.include?("views/")
      end

      score
    end

    def extracted_terms
      terms = @normalized.scan(/[a-z0-9_]+/)
      terms += ["layer1", "layer1", "blockchain"] if @normalized.include?("layer1")
      terms.uniq
    end

    def architecture_question?
      @normalized.match?(/pipeline|architecture|fonctionne|parcours|traitement|complet|de bout en bout/)
    end
  end
end