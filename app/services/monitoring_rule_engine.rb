# app/services/monitoring_rule_engine.rb
class MonitoringRuleEngine
  # context = {
  #   blockchain:        @blockchain (hash RPC),
  #   mempool:           @mempool (hash RPC),
  #   mempool_security:  @mempool_security (hash du service),
  #   lightning_status:  @lightning_status (hash du service),
  #   brc20_scan_stats:  @brc20_scan_stats (hash du coverage_service)
  # }
  def initialize(blockchain:, mempool:, mempool_security:, lightning_status:, brc20_scan_stats:)
    @blockchain        = blockchain || {}
    @mempool           = mempool || {}
    @mempool_security  = mempool_security || {}
    @lightning_status  = lightning_status || {}
    @brc20_scan_stats  = brc20_scan_stats || {}
  end

  def call
    rules = []
    add_blockchain_rules(rules)
    add_mempool_rules(rules)
    add_lightning_rules(rules)
    add_brc20_rules(rules)
    rules
  end

  private

  def add_blockchain_rules(rules)
    progress = @blockchain["verificationprogress"].to_f
    headers  = @blockchain["headers"].to_i
    blocks   = @blockchain["blocks"].to_i
    diff     = headers - blocks

    # Nœud pas encore full sync
    if progress < 0.999
      rules << {
        id: :node_sync_lagging,
        scope: :blockchain,
        level: :info,
        title: "Nœud Bitcoin en rattrapage",
        message: "Le nœud n’est pas encore totalement synchronisé (#{(progress * 100).round(2)} %).",
        hint: "Certaines données peuvent être incomplètes tant que le nœud n’a pas téléchargé tous les blocs.",
      }
    end

    # Décalage headers / blocks trop important
    if diff > 5
      rules << {
        id: :headers_blocks_gap,
        scope: :blockchain,
        level: :warning,
        title: "Décalage entre headers et blocs",
        message: "Le nœud connaît #{headers} headers mais seulement #{blocks} blocs (différence : #{diff}).",
        hint: "Vérifie la connectivité réseau et le disque si ce décalage persiste dans le temps.",
      }
    end
  end

  def add_mempool_rules(rules)
    level  = @mempool_security[:level]
    mem_mb = @mempool_security[:mem_mb]
    min_sat_vb = @mempool_security[:min_sat_vb]
    tx_count   = @mempool_security[:tx_count]

    return unless level

    case level
    when :low
      rules << {
        id: :mempool_fluid,
        scope: :mempool,
        level: :info,
        title: "Réseau fluide",
        message: "La mempool est peu chargée (~#{mem_mb} MB, #{tx_count} tx, min ~#{min_sat_vb} sat/vB).",
        hint: "Les transactions peuvent être envoyées avec des frais bas, confirmations rapides probables.",
      }
    when :medium
      rules << {
        id: :mempool_medium,
        scope: :mempool,
        level: :warning,
        title: "Mempool modérément chargée",
        message: "La mempool est modérément chargée (~#{mem_mb} MB, #{tx_count} tx, min ~#{min_sat_vb} sat/vB).",
        hint: "Évite les frais trop bas. Utilise des frais moyens si tu veux une confirmation sans trop attendre.",
      }
    when :high
      rules << {
        id: :mempool_high,
        scope: :mempool,
        level: :warning,
        title: "Réseau sous tension",
        message: "La mempool est fortement chargée (~#{mem_mb} MB, #{tx_count} tx, min ~#{min_sat_vb} sat/vB).",
        hint: "Pour les petits montants, privilégie Lightning. Garde l’on-chain pour les paiements importants.",
      }
    when :critical
      rules << {
        id: :mempool_critical,
        scope: :mempool,
        level: :critical,
        title: "Réseau congestionné",
        message: "La mempool est en congestion sévère (> #{mem_mb} MB, min ~#{min_sat_vb} sat/vB).",
        hint: "Diffère les transactions non urgentes. Pour les paiements sensibles, privilégie Lightning ou attends.",
      }
    end
  end

  def add_lightning_rules(rules)
    enabled          = @lightning_status[:enabled]
    active_channels  = @lightning_status[:active_channels].to_i
    total_channels   = @lightning_status[:num_channels].to_i
    local_sat        = @lightning_status[:local_balance_sat].to_i
    remote_sat       = @lightning_status[:remote_balance_sat].to_i
    synced_chain     = !!@lightning_status[:synced_to_chain]
    synced_graph     = !!@lightning_status[:synced_to_graph]

    unless enabled
      rules << {
        id: :ln_disabled,
        scope: :lightning,
        level: :warning,
        title: "Nœud Lightning indisponible",
        message: "Le nœud Lightning n’est pas accessible ou désactivé.",
        hint: "Vérifie le container LND dans BTCPay, ou désactive temporairement l’affichage LN dans le dashboard.",
      }
      return
    end

    # Nœud Lightning OK mais peu de canaux
    if total_channels.zero?
      rules << {
        id: :ln_no_channels,
        scope: :lightning,
        level: :warning,
        title: "Aucun canal Lightning ouvert",
        message: "Le nœud Lightning est en ligne mais aucun canal n’est ouvert.",
        hint: "Ouvre au moins un canal vers un bon routeur pour pouvoir envoyer et recevoir des paiements Lightning.",
      }
    elsif active_channels.zero?
      rules << {
        id: :ln_no_active_channels,
        scope: :lightning,
        level: :warning,
        title: "Aucun canal Lightning actif",
        message: "Le nœud possède #{total_channels} canaux mais aucun n’est actuellement actif.",
        hint: "Vérifie la connectivité réseau, la liquidité, et que les pairs sont joignables.",
      }
    else
      rules << {
        id: :ln_ready,
        scope: :lightning,
        level: :info,
        title: "Nœud Lightning opérationnel",
        message: "Le nœud Lightning a #{active_channels}/#{total_channels} canaux actifs, prêt à router des paiements.",
        hint: "Tu peux utiliser Lightning pour des paiements rapides en boutique ou en ligne.",
      }
    end

    # Ratio local / remote très déséquilibré
    total_liq = local_sat + remote_sat
    if total_liq > 0
      local_ratio = (local_sat.to_f / total_liq).round(2)

      if local_ratio < 0.1
        rules << {
          id: :ln_low_local_liquidity,
          scope: :lightning,
          level: :warning,
          title: "Liquidité locale faible",
          message: "Seule une petite partie de la capacité Lightning est disponible côté local (#{(local_ratio * 100).round}% environ).",
          hint: "Tu risques d’être limité pour envoyer des paiements. Songe à rééquilibrer ou ouvrir de nouveaux canaux.",
        }
      elsif local_ratio > 0.9
        rules << {
          id: :ln_low_remote_liquidity,
          scope: :lightning,
          level: :warning,
          title: "Liquidité remote faible",
          message: "La plupart de la capacité Lightning est du côté local.",
          hint: "Tu peux envoyer facilement mais tu risques d’avoir du mal à recevoir des paiements entrants.",
        }
      end
    end

    # Problème de synchro LN
    unless synced_chain && synced_graph
      rules << {
        id: :ln_not_fully_synced,
        scope: :lightning,
        level: :warning,
        title: "Nœud Lightning en cours de synchronisation",
        message: "Le nœud Lightning n’est pas totalement synchronisé (chaîne ou graphe de canaux).",
        hint: "Certaines routes peuvent être indisponibles tant que la synchro n’est pas complète.",
      }
    end
  end

  def add_brc20_rules(rules)
    return if @brc20_scan_stats.empty?

    coverage_pct   = @brc20_scan_stats[:coverage_pct].to_f
    missing_blocks = @brc20_scan_stats[:missing_blocks].to_i

    if missing_blocks.zero? && coverage_pct >= 99.9
      rules << {
        id: :brc20_index_ok,
        scope: :brc20,
        level: :info,
        title: "Index BRC-20 synchronisé",
        message: "L’index BRC-20 couvre l’ensemble de la fenêtre définie (#{coverage_pct.round(2)} %).",
        hint: "Les statistiques BRC-20 peuvent être utilisées comme base d’analyse.",
      }
    else
      rules << {
        id: :brc20_index_partial,
        scope: :brc20,
        level: :warning,
        title: "Index BRC-20 incomplet",
        message: "L’index BRC-20 ne couvre que ~#{coverage_pct.round(2)} % de la fenêtre, avec #{missing_blocks} blocs manquants.",
        hint: "Lance un rescan ou laisse le cron rattraper les blocs manquants avant d’utiliser les chiffres pour une analyse fine.",
      }
    end
  end
end
