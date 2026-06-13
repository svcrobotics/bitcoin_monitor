# frozen_string_literal: true

module Intelligence
  class ClusterAssistant
    def self.call(question:, context:)
      new(question:, context:).call
    end

    def initialize(question:, context:)
      @question = question.to_s
      @context = context || {}
    end

    def call
      sync = @context[:sync] || {}
      activity = @context[:activity] || {}
      queues = @context[:queues] || {}

      warnings = []

      warnings << "le scanner de clusters accuse du retard" if sync[:scanner_lag].to_i > 5

      warnings << "cluster_inputs accuse du retard sur Layer 1" if sync[:input_lag].to_i > 5

      warnings << "des queues Cluster contiennent du backlog" if queues.values.any? { |v| v.to_i > 100 }

      if activity[:last_actor_profile_at].present? &&
         activity[:last_actor_profile_at] < 6.hours.ago
        warnings << "les Actor Profiles semblent ne plus être mis à jour récemment"
      end

      if healthy?(sync, queues)
        answer = +"Le moteur de clustering fonctionne normalement. Les données de cluster_inputs sont synchronisées avec Layer 1 et le scanner traite les nouveaux blocs sans retard significatif."
      else
        answer = +"Le moteur de clustering reste opérationnel mais certains composants méritent une surveillance."
      end

      if warnings.any?
        answer << "\n\nPoint à surveiller : #{warnings.join(', ')}."
      else
        answer << "\n\nPoint à surveiller : aucun signal critique immédiat."
      end

      answer << "\n\nAction recommandée : surveiller la progression des Actor Profiles et vérifier que le scanner reste aligné sur les derniers blocs."

      answer
    end

    private

    def healthy?(sync, queues)
      sync[:input_lag].to_i <= 5 &&
        sync[:scanner_lag].to_i <= 5 &&
        queues.values.none? { |v| v.to_i > 100 }
    end
  end
end