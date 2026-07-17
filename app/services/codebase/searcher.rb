# frozen_string_literal: true

module Codebase
  class Searcher
    DEFAULT_LIMIT = 8
    CANDIDATE_LIMIT = 40

    BOOST_PATHS = [
      "app/services/layer1/",
      "app/jobs/layer1/",
      "app/services/clusters/",
      "app/jobs/clusters/",
      "app/services/actor_profiles/",
      "app/jobs/actor_profiles/",
      "app/services/actor_labels/",
      "app/jobs/actor_labels/",
      "app/services/intelligence/",
      "app/controllers/ai/",
      "app/controllers/questions/",
      "app/controllers/tansa_heartbeat_controller.rb",
      "app/views/questions/answers/",
      "app/javascript/controllers/system_heartbeat_controller.js"
    ].freeze

    PENALTY_PATHS = [
      "app/views/layouts/",
      "app/views/shared/",
      "app/helpers/",
      "app/assets/",
      "app/javascript/channels/"
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
      return [] if CodeChunk.count.zero?

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
        score -= 4 if path.start_with?(prefix)
      end

      extracted_terms.each do |term|
        score += 3 if path.include?(term)
        score += 1 if content.include?(term)
      end

      if architecture_question?
        score += 5 if path.include?("layer1/")
        score += 5 if path.include?("clusters/")
        score += 5 if path.include?("actor_profiles/")
        score += 4 if path.include?("strict")
        score += 4 if path.include?("health")
        score += 3 if path.include?("audit")
        score += 3 if path.include?("pipeline")
        score += 3 if path.include?("heartbeat")
        score += 2 if path.include?("questions/answers")
      end

      score
    end

    def extracted_terms
      terms = @normalized.scan(/[a-z0-9_]+/)

      terms += ["layer1", "strict", "blockchain"] if @normalized.include?("layer1")
      terms += ["cluster", "clusters", "address"] if @normalized.include?("cluster")
      terms += ["actor_profiles", "actor", "profile", "profiles"] if @normalized.match?(/actor ?profile|actorprofile|profil/)
      terms += ["actor_labels", "label", "labels"] if @normalized.match?(/actor ?label|actorlabel|label/)
      terms += ["heartbeat", "topbar"] if @normalized.match?(/topbar|heartbeat|live/)
      terms += ["question", "answer", "dashboard"] if @normalized.match?(/question|réponse|reponse|dashboard/)

      terms.uniq
    end

    def architecture_question?
      @normalized.match?(/pipeline|architecture|fonctionne|parcours|traitement|complet|de bout en bout|à quoi|a quoi|sert|module|capacité|capacite/)
    end
  end
end
