# frozen_string_literal: true

module ClusterEventsHelper
  def cluster_event_label(signal_type)
    case signal_type.to_s
    when "large_outflow"
      "Gros outflow"
    when "large_inflow"
      "Accumulation"
    when "whale_cluster_activity"
      "Whale activity"
    when "activity_spike", "sudden_activity"
      "Activité inhabituelle"
    when "cluster_merge"
      "Fusion de clusters"
    when "large_link_creation"
      "Expansion du graphe"
    when "cluster_activation", "cluster_reactivation"
      "Cluster ancien actif"
    else
      signal_type.to_s.humanize
    end
  end

  def cluster_event_reading(signal_type)
    case signal_type.to_s
    when "large_outflow"
      "Gros mouvement sortant. Peut indiquer pression vendeuse, transfert vers plateforme ou réorganisation interne."
    when "large_inflow"
      "Accumulation ou réception importante par une entité."
    when "whale_cluster_activity"
      "Une grosse entité devient active. Ce n’est pas forcément vendeur, mais c’est important à surveiller."
    when "activity_spike", "sudden_activity"
      "Changement brutal d’activité du cluster."
    when "cluster_merge"
      "Évolution du graphe. Deux groupes d’adresses semblent reliés."
    when "large_link_creation"
      "Expansion forte du cluster. Peut révéler une entité plus grande que prévu."
    when "cluster_activation", "cluster_reactivation"
      "Un cluster déjà connu par Bitcoin Monitor montre une activité récente importante."
    else
      "Événement cluster utile pour comprendre l’évolution du graphe."
    end
  end

  def cluster_event_next_step(signal_type)
    case signal_type.to_s
    when "large_outflow"
      "À vérifier : destination, répétition du mouvement, lien avec exchange-like."
    when "large_inflow"
      "À vérifier : origine des fonds, fréquence, type du cluster."
    when "whale_cluster_activity"
      "À vérifier : mouvement isolé ou série, montant cumulé, direction des flux."
    when "activity_spike", "sudden_activity"
      "À vérifier : pic ponctuel ou activité durable, volume BTC associé."
    when "cluster_merge"
      "Utilité : améliore la connaissance de l’entité, mais ce n’est pas un signal marché direct."
    when "large_link_creation"
      "À vérifier : comportement exchange-like, répétition, taille du cluster."
    when "cluster_activation", "cluster_reactivation"
      "À vérifier : montant déplacé, répétition du signal, destination. La vraie durée de dormance sera suivie à partir de maintenant."
    else
      "À vérifier : score, source, répétition et cluster concerné."
    end
  end

  def cluster_event_severity_class(severity)
    case severity.to_s
    when "high"
      "text-rose-300 bg-rose-500/10 border border-rose-500/20"
    when "medium"
      "text-amber-300 bg-amber-500/10 border border-amber-500/20"
    else
      "text-gray-300 bg-gray-500/10 border border-gray-500/20"
    end
  end

  def cluster_event_score_class(score)
    score = score.to_i

    if score >= 90
      "text-rose-300 bg-rose-500/10 border border-rose-500/20"
    elsif score >= 70
      "text-orange-300 bg-orange-500/10 border border-orange-500/20"
    else
      "text-amber-300 bg-amber-500/10 border border-amber-500/20"
    end
  end

  def cluster_event_source_class(source)
    case source.to_s
    when "cluster_business"
      "text-orange-300 bg-orange-500/10 border border-orange-500/20"
    when "cluster_realtime"
      "text-sky-300 bg-sky-500/10 border border-sky-500/20"
    else
      "text-gray-300 bg-gray-500/10 border border-gray-500/20"
    end
  end
end