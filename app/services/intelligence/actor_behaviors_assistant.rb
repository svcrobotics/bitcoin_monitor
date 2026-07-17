# frozen_string_literal: true

module Intelligence
  class ActorBehaviorsAssistant
    def self.call(question:, context:)
      new(question:, context:).call
    end

    def initialize(question:, context:)
      @question = question.to_s
      @context = context.to_h
    end

    def call
      return unavailable_answer unless context[:status] == "available"

      [
        "État certifié ActorBehavior disponible.",
        coverage_answer,
        backlog_answer
      ].join("\n\n")
    end

    private

    attr_reader :context, :question

    def coverage_answer
      eligible = context[:actor_profiles_eligible]
      certified = context[:actor_behaviors_certified]
      coverage = context[:coverage]

      "Couverture certifiée : #{value(certified)} snapshot(s) " \
        "sur #{value(eligible)} profil(s) ActorProfile certifié(s), " \
        "soit #{percentage(coverage)}."
    end

    def backlog_answer
      missing = context[:actor_behaviors_missing]
      stale = context[:actor_behaviors_stale]

      "Backlog certifié : #{value(missing)} manquant(s) et " \
        "#{value(stale)} périmé(s)."
    end

    def unavailable_answer
      "Aucune donnée certifiée ActorBehavior n’est disponible."
    end

    def value(number)
      number.nil? ? "indisponible" : number.to_i.to_s
    end

    def percentage(ratio)
      return "indisponible" if ratio.nil?

      format("%.2f %%", ratio.to_f * 100)
    end
  end
end
