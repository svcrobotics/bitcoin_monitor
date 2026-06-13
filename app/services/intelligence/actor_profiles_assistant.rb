# frozen_string_literal: true

module Intelligence
  class ActorProfilesAssistant
    def self.call(question:, context:)
      new(question:, context:).call
    end

    def initialize(question:, context:)
      @question = question.to_s
      @context = context || {}
    end

    def call
      activity = @context[:activity] || {}
      queues = @context[:queues] || {}
      counts = @context[:counts] || {}

      warnings = []
      warnings << "les Actor Labels semblent anciens" if activity[:last_actor_label_at].present? && activity[:last_actor_label_at] < 6.hours.ago
      warnings << "des profils acteurs sont en attente" if counts[:dirty_actor_profiles].to_i.positive?
      warnings << "des queues Actor Profiles contiennent du backlog" if queues.values.any? { |v| v.to_i > 100 }

      answer =
        if @context[:status].to_s == "healthy"
          +"Actor Profiles fonctionne normalement. Les profils acteurs sont récents et aucune queue de traitement n'est en retard."
        else
          +"Actor Profiles nécessite une surveillance : certains indicateurs ne sont pas dans une zone nominale."
        end

      answer << "\n\nPoint à surveiller : #{warnings.any? ? warnings.join(', ') : 'aucun signal critique immédiat'}."
      answer << "\n\nAction recommandée : surveiller la fraîcheur des Actor Labels, car ils dépendent directement des Actor Profiles."

      answer
    end
  end
end