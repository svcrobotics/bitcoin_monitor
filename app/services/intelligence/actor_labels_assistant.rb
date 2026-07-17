# frozen_string_literal: true

module Intelligence
  class ActorLabelsAssistant
    def self.call(question:, context:)
      new(
        question: question,
        context: context
      ).call
    end

    def initialize(question:, context:)
      @question = question.to_s
      @context = context || {}
    end

    def call
      pipeline =
        context[:pipeline] || {}

      behaviors =
        context[:actor_behaviors] || {}

      labels =
        context[:actor_labels] || {}

      version =
        behaviors[:behavior_version].presence ||
        pipeline[:required_behavior_version].presence ||
        "inconnue"

      answer =
        +"ActorLabels est raccordé au pipeline strict via ActorBehavior."

      answer <<
        "\n\nSa source comportementale certifiée est ActorBehavior " \
        "#{version}. Les règles ActorLabels ne lisent pas " \
        "directement ActorProfile pour classifier."

      if pipeline[:dependency_ready] == true || behaviors[:ready] == true
        answer <<
          "\n\nActorBehavior expose des snapshots certifiés. " \
          "ActorLabels peut les traiter progressivement sans attendre " \
          "100 % de couverture."
      else
        answer <<
          "\n\nActorBehavior est encore en construction : " \
          "#{behaviors[:snapshots_current].to_i} snapshots actuels, " \
          "#{behaviors[:snapshots_missing].to_i} manquants, " \
          "#{format('%.2f', behaviors[:coverage_percent].to_f)} % " \
          "de couverture."
      end

      answer <<
        "\n\nRègles comportementales actives : whale_like, " \
        "whale_candidate, exchange_like, service_like et " \
        "etf_candidate. etf_like reste une identité vérifiée " \
        "séparément, retail_like reste désactivé."

      answer <<
        "\n\nLabels actuellement enregistrés : " \
        "#{labels[:total].to_i}. Zéro label est un résultat valide " \
        "si aucun snapshot ne satisfait les seuils certifiés."

      answer <<
        "\n\nLe writer ne supprime que les labels de sa propre source : " \
        "#{pipeline[:source] || 'actor_labels_from_behavior_strict_v2'}."

      answer
    end

    private

    attr_reader :question, :context
  end
end
