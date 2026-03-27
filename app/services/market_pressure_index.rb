# frozen_string_literal: true

# app/services/market_pressure_index.rb
#
# Objectif:
# - Donner un "état du marché" lisible (fenêtre glissante)
# - Basé sur données factuelles (flows exchanges, volatilité, events)
# - Aucun "achat/vente", aucune prédiction
#
class MarketPressureIndex
  Result = Struct.new(
    :key,       # :high | :cleanup | :calm
    :label,
    :badge_cls,
    :summary,
    :window_days,
    :facts,
    keyword_init: true
  )

  def self.call(
    window_days: 30,
    ratio30: nil,
    vol_pct: nil,
    inflow_btc: nil,
    outflow_btc: nil,
    netflow_btc: nil,
    whale_events: nil
  )
    r = ratio30&.to_f
    v = vol_pct&.to_f
    inflow  = inflow_btc&.to_f
    outflow = outflow_btc&.to_f
    net     = netflow_btc&.to_f
    whales  = whale_events.to_i

    # --- Seuils v1 ---
    ratio_high = 2.0

    vol_high = 2.0  # %/jour
    vol_mid  = 1.2

    whales_high = 20
    whales_mid  = 8

    # Fallback si ratio30 absent/0: netflow/jour + vol
    net_per_day = net ? (net.abs / window_days.to_f) : nil
    net_high_per_day = 300.0
    net_mid_per_day  = 150.0

    has_ratio_signal = r && r > 0.0
    ratio_is_high    = has_ratio_signal && r >= ratio_high

    if ratio_is_high && ((v && v >= vol_high) || whales >= whales_high)
      key = :high
      label = "🟥 Pression spéculative élevée"
      badge_cls = "text-rose-200 bg-rose-500/10 border-rose-700/50"
      summary = "Flux anormalement élevés vers les exchanges + agitation élevée (volatilité / événements)."

    elsif ratio_is_high
      key = :cleanup
      label = "🟧 Phase de nettoyage"
      badge_cls = "text-amber-200 bg-amber-500/10 border-amber-700/50"
      summary = "Flux élevés vers les exchanges, mais le marché digère (agitation contenue)."

    elsif (!has_ratio_signal) && net_per_day && v
      # Fallback sans ratio: netflow/jour + vol
      if net_per_day >= net_high_per_day && v >= vol_high
        key = :high
        label = "🟥 Pression spéculative élevée"
        badge_cls = "text-rose-200 bg-rose-500/10 border-rose-700/50"
        summary = "Flux nets importants vers exchanges + volatilité élevée : pression spéculative notable."
      elsif net_per_day >= net_mid_per_day || (v >= vol_mid) || (whales >= whales_mid)
        key = :cleanup
        label = "🟧 Phase de nettoyage"
        badge_cls = "text-amber-200 bg-amber-500/10 border-amber-700/50"
        summary = "Flux nets / volatilité indiquent une phase de digestion : excès en cours de purge."
      else
        key = :calm
        label = "🟩 Marché apaisé"
        badge_cls = "text-emerald-200 bg-emerald-500/10 border-emerald-700/50"
        summary = "Pas de tension marquée détectée : dynamique plus stable."
      end

    else
      key = :calm
      label = "🟩 Marché apaisé"
      badge_cls = "text-emerald-200 bg-emerald-500/10 border-emerald-700/50"
      summary = "Pas d’excès marqué dans les flux vers exchanges ; dynamique plus stable."
    end

    facts = {
      ratio30: r,
      vol_pct: v,
      inflow_btc: inflow,
      outflow_btc: outflow,
      netflow_btc: net,
      whale_events: whales,
      net_per_day: net_per_day
    }

    Result.new(
      key: key,
      label: label,
      badge_cls: badge_cls,
      summary: summary,
      window_days: window_days,
      facts: facts
    )
  end
end
