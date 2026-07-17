# frozen_string_literal: true

module Intelligence
  class ActorBehaviorsAssistant
    def self.call(question:, context:)
      new(question:, context:).call
    end

    def initialize(question:, context:)
      @question = question.to_s
      @context = context || {}
    end

    def call
      operational =
        @context[:operational] || {}

      status =
        @context[:status].to_s

      current =
        operational[:snapshots_current].to_i

      certified =
        operational[:actor_profiles_certified].to_i

      missing =
        operational[:snapshots_missing].to_i

      stale =
        operational[:snapshots_stale].to_i

      coverage =
        operational[:coverage_percent].to_f

      answer =
        case status
        when "shadow_ready"
          +"ActorBehavior est prêt en mode shadow. Tous les profils ActorProfile certifiés disposent d’un snapshot de comportement courant."
        when "shadow_building"
          +"ActorBehavior fonctionne en mode shadow et poursuit la construction des snapshots de comportement."
        when "shadow_empty"
          +"ActorBehavior est en mode shadow, mais aucun snapshot de comportement exploitable n’est encore disponible."
        else
          +"L’état ActorBehavior n’a pas pu être déterminé précisément."
        end

      answer << "\n\nCouverture observée : "
      answer << "#{current} snapshot(s) courant(s) sur "
      answer << "#{certified} profil(s) certifié(s), "
      answer << "soit #{format('%.2f', coverage)} %."

      answer << "\n\nBacklog : "
      answer << "#{missing} manquant(s) et "
      answer << "#{stale} périmé(s)."

      last_run_status =
        operational[:last_run_status].to_s

      if last_run_status.present?
        answer << "\n\nDernier run : #{last_run_status}"

        duration_ms =
          operational[:last_run_duration_ms]

        if duration_ms.present?
          answer << " en #{duration_ms.to_i} ms"
        end

        answer << "."
      end

      answer << "\n\nActorBehavior ne produit actuellement aucun ActorLabel : le module reste isolé en mode shadow."

      answer
    end
  end
end
