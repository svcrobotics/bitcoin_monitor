# frozen_string_literal: true

class Layer1HealthController < ApplicationController
  def show
    snapshot = Layer1::CachedHealthSnapshot.read.with_indifferent_access

    context = {
      module: "layer1_health",
      raw_snapshot: snapshot,
      source: "layer1_health",
      today: {
        updated_at: Time.current,
        events_count: snapshot.dig(:counts, :block_buffers)
      }
    }

    answer = build_answer(snapshot)

    render partial: "ai/dashboard_answer",
           locals: {
             context: context,
             answer: answer
           }
  end

  private

  def build_answer(snapshot)
    case snapshot[:status]
    when "healthy"
      if snapshot.dig(:activity, :pipeline_state) == "idle_synced"
        "Aucune anomalie détectée. Layer 1 est synchronisé et l'ensemble des composants observés fonctionnent normalement. Aucun retard ni accumulation inhabituelle ne nécessite une intervention."
      else
        "Layer 1 fonctionne normalement. Des traitements sont actuellement en cours mais aucun indicateur ne suggère un retard ou un risque opérationnel."
      end
    when "warning"
      "Surveillance recommandée. Certains indicateurs montrent un ralentissement ou une accumulation modérée de travail. La situation n'est pas critique mais mérite d'être suivie."
    when "critical"
      "Attention requise. Layer 1 présente des signes de blocage ou d'accumulation anormale. Vérifie les workers, les files Sidekiq et les buffers Redis."
    else
      "État Layer 1 indéterminé. Une vérification manuelle des composants principaux est recommandée."
    end
  end
end