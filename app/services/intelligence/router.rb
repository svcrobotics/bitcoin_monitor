# frozen_string_literal: true

module Intelligence
  class Router
    CODEBASE_KEYWORDS = [
      "code",
      "code source",
      "fichier",
      "classe",
      "module",
      "méthode",
      "methode",
      "service",
      "controller",
      "job",
      "model",
      "migration",
      "constant",
      "constante",
      "où est défini",
      "ou est defini",
      "où se trouve",
      "ou se trouve"
    ].freeze

    LAYER1_KEYWORDS = [
      "layer 1", "layer1", "blockchain", "utxo", "outputs", "spent",
      "block processing", "blocks", "sync", "synchronisation",
      "lag layer 1", "output flusher", "spent flusher", "block buffer"
    ].freeze

    CLUSTER_KEYWORDS = [
      "cluster", "clusters", "cluster health", "scanner cluster",
      "cluster scanner"
    ].freeze

    ACTOR_PROFILES_KEYWORDS = [
      "actorprofile", "actor profile", "actor profiles",
      "profil acteur", "profils acteurs"
    ].freeze

    ACTOR_LABELS_KEYWORDS = [
      "actorlabel", "actorlabels", "actor label", "actor labels",
      "labels acteurs", "label acteur"
    ].freeze

    ETF_CANDIDATE_KEYWORDS = [
      "etf", "etf candidate", "etf candidates", "fonds bitcoin",
      "fonds btc", "institutionnel", "institutionnels",
      "accumulation institutionnelle"
    ].freeze

    SYSTEM_KEYWORDS = [
      "système", "system", "application", "app", "état", "etat",
      "santé", "sante", "sidekiq", "redis", "job", "jobs",
      "queue", "queues", "worker", "workers", "recovery",
      "retard", "latence", "latency", "exchange runtime", "pipeline"
    ].freeze

    def self.call(question)
      new(question).call
    end

    def initialize(question)
      @raw_question = question.to_s.strip
      @question = @raw_question.downcase
    end

    def call
      if codebase_question?
        {
          intent: :codebase,
          provider: :openai,
          source: :code_chunks,
          context: nil
        }
      elsif actor_labels_question?
        {
          intent: :actor_labels_health,
          provider: :local,
          source: :actor_labels_health,
          context: Intelligence::ContextBuilder.actor_labels_health
        }
      elsif actor_profiles_question?
        {
          intent: :actor_profiles_health,
          provider: :local,
          source: :actor_profiles_health,
          context: Intelligence::ContextBuilder.actor_profiles_health
        }
      elsif cluster_question?
        {
          intent: :cluster_health,
          provider: :local,
          source: :cluster_health,
          context: Intelligence::ContextBuilder.cluster_health
        }
      elsif layer1_question?
        {
          intent: :layer1_health,
          provider: :local,
          source: :layer1_health,
          context: Intelligence::ContextBuilder.layer1_health
        }
      elsif system_question?
        {
          intent: :system_health,
          provider: :local,
          source: :system_health,
          context: Intelligence::ContextBuilder.system_health
        }
      elsif etf_candidates_question?
        {
          intent: :etf_candidates,
          provider: :local,
          source: :etf_candidates,
          context: Intelligence::ContextBuilder.etf_candidates
        }
      else
        {
          intent: :exchange_flow,
          provider: :openai,
          source: :exchange_flow,
          context: Intelligence::ContextBuilder.exchange_flow
        }
      end
    end

    private

    def codebase_question?
      return true if @raw_question.match?(/[A-Z][A-Za-z0-9_]*::[A-Z]/)

      architecture_keywords = [
        "comment fonctionne",
        "pipeline",
        "architecture",
        "traitement",
        "parcours",
        "workflow",
        "que fait",
        "comment arrive",
        "comment les",
        "explique"
      ]

      return true if architecture_keywords.any? do |keyword|
        @question.include?(keyword)
      end

      CODEBASE_KEYWORDS.any? do |keyword|
        @question.include?(keyword)
      end
    end

    def layer1_question?
      LAYER1_KEYWORDS.any? { |keyword| @question.include?(keyword) }
    end

    def cluster_question?
      CLUSTER_KEYWORDS.any? { |keyword| @question.include?(keyword) }
    end

    def actor_profiles_question?
      ACTOR_PROFILES_KEYWORDS.any? { |keyword| @question.include?(keyword) }
    end

    def actor_labels_question?
      ACTOR_LABELS_KEYWORDS.any? { |keyword| @question.include?(keyword) }
    end

    def system_question?
      SYSTEM_KEYWORDS.any? { |keyword| @question.include?(keyword) }
    end

    def etf_candidates_question?
      ETF_CANDIDATE_KEYWORDS.any? { |keyword| @question.include?(keyword) }
    end
  end
end