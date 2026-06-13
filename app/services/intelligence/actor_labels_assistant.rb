# frozen_string_literal: true

module Intelligence
  class ActorLabelsAssistant
    def self.call(question:, context:)
      new(question:, context:).call
    end

    def initialize(question:, context:)
      @question = question.to_s
      @context = context || {}
    end

    def call
      counts = @context[:counts] || {}
      activity = @context[:activity] || {}
      queues = @context[:queues] || {}

      warnings = []

      if activity[:last_actor_label_at].present? &&
         activity[:last_actor_label_at] < 6.hours.ago
        warnings << "les Actor Labels semblent anciens"
      end

      if activity[:last_actor_profile_at].present? &&
         activity[:last_actor_label_at].present? &&
         activity[:last_actor_label_at] < activity[:last_actor_profile_at]
        warnings << "les Actor Labels sont en retard par rapport aux Actor Profiles"
      end

      warnings << "la queue actor_labels contient du backlog" if queues["actor_labels"].to_i > 100

      if @context[:status].to_s == "healthy"
        answer = +"Actor Labels fonctionne normalement. Les classifications économiques sont récentes."
      else
        answer = +"Actor Labels nécessite une surveillance : les classifications ne semblent pas à jour par rapport aux profils acteurs."
      end

      answer << "\n\nDistribution actuelle : #{counts[:exchange_like].to_i} exchange-like, #{counts[:whale_like].to_i} whale-like, #{counts[:etf_like].to_i} ETF-like."

      answer << "\n\nPoint à surveiller : #{warnings.any? ? warnings.join(', ') : 'aucun signal critique immédiat'}."

      answer << "\n\nAction recommandée : relancer ou vérifier le pipeline de rafraîchissement des labels depuis les Actor Profiles."

      answer
    end
  end
end
