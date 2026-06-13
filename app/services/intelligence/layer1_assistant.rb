# frozen_string_literal: true

module Intelligence
  class Layer1Assistant
    def self.call(question:, context:)
      new(question:, context:).call
    end

    def initialize(question:, context:)
      @question = question.to_s
      @context = context || {}
    end

    def call
      sync = @context[:sync] || {}
      buffers = @context[:buffers] || {}
      queues = @context[:queues] || {}
      activity = @context[:activity] || {}

      last_audit = Layer1AuditRun.order(created_at: :desc).first
      audit_checks = last_audit&.checks || {}
      audit_total = audit_checks.size
      audit_ok = audit_checks.count { |_name, result| result["passed"] }
      audit_compliance = audit_total.zero? ? nil : ((audit_ok.to_f / audit_total) * 100).round

      answer = +""

      answer << layer1_state(sync, buffers, activity)
      answer << "\n\n"
      answer << audit_state(last_audit, audit_total, audit_ok, audit_compliance)
      answer << "\n\n"
      answer << watch_points(sync, buffers, queues, activity, audit_compliance)
      answer << "\n\n"
      answer << conclusion(sync, buffers, activity, audit_compliance)

      answer
    end

    private

    def layer1_state(sync, buffers, activity)
      if healthy?(sync, buffers, activity)
        "Layer1 est opérationnel : le pipeline est synchronisé, le lag est nul et les buffers Redis sont sous contrôle."
      else
        "Layer1 nécessite une surveillance : certains indicateurs sortent de la zone nominale."
      end
    end

    def audit_state(last_audit, total, ok, compliance)
      return "Audit Layer1 : aucun audit récent n’est disponible. Il faut lancer une vérification Bitcoin Core ↔ Tansa." unless last_audit

      if compliance == 100
        "Preuve des données : le dernier audit du bloc #{last_audit.audited_height} est conforme à 100% avec Bitcoin Core (#{ok}/#{total} contrôles OK)."
      else
        "Preuve des données : le dernier audit du bloc #{last_audit.audited_height} indique une conformité de #{compliance}% (#{ok}/#{total} contrôles OK). Une divergence doit être analysée."
      end
    end

    def watch_points(sync, buffers, queues, activity, audit_compliance)
      warnings = []

      warnings << "lag Layer1 positif" if sync[:lag].to_i.positive?
      warnings << "buffer outputs élevé" if buffers[:outputs].to_i > 200_000
      warnings << "buffer spent élevé" if buffers[:spent].to_i > 50_000
      warnings << "queue spent_resolve élevée (#{queues["spent_resolve"]} jobs)" if queues["spent_resolve"].to_i > 100
      warnings << "pipeline #{activity[:pipeline_state]}" unless %w[active idle_synced].include?(activity[:pipeline_state].to_s)
      warnings << "audit non conforme" if audit_compliance && audit_compliance < 100

      if warnings.any?
        "Points à surveiller : #{warnings.join(', ')}."
      else
        "Points à surveiller : aucun signal critique immédiat. Le point sensible reste le délai temporaire entre le traitement d’un bloc et l’écriture complète de ses outputs."
      end
    end

    def conclusion(sync, buffers, activity, audit_compliance)
      if healthy?(sync, buffers, activity) && audit_compliance == 100
        "Conclusion : Layer1 peut être considéré comme une base fiable pour les analyses supérieures de Tansa : clusters, actors, exchanges, flows et réponses IA."
      else
        "Conclusion : les données Layer1 doivent rester sous surveillance avant d’être utilisées comme base de confiance complète."
      end
    end

    def healthy?(sync, buffers, activity)
      sync[:lag].to_i.zero? &&
        buffers[:outputs].to_i < 200_000 &&
        buffers[:spent].to_i < 50_000 &&
        %w[active idle_synced].include?(activity[:pipeline_state].to_s)
    end
  end
end