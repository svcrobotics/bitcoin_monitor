# frozen_string_literal: true

# app/services/market_maturity_index.rb
#
# Objectif:
# - Qualifier la maturité du marché (fenêtre glissante, ex 30j)
# - Basé sur faits observés: volatilité + fréquence d'événements majeurs
# - Aucune prédiction, aucun signal buy/sell
#
class MarketMaturityIndex
  Result = Struct.new(
    :key,       # :immature | :transition | :mature
    :label,
    :badge_cls,
    :summary,
    :window_days,
    :facts,
    keyword_init: true
  )

  def self.call(
    window_days: 30,
    vol_pct: nil,
    whale_events: nil
  )
    v = vol_pct&.to_f
    w = whale_events.to_i

    # ---- Seuils v1 ----
    vol_high = 2.0
    vol_mid  = 1.2

    whales_high = 20
    whales_mid  = 8

    score = 0
    if v
      score += 2 if v >= vol_high
      score += 1 if v >= vol_mid && v < vol_high
    end
    score += 2 if w >= whales_high
    score += 1 if w >= whales_mid && w < whales_high

    if score >= 3
      key = :immature
      label = "🟥 Marché immature"
      badge_cls = "text-rose-200 bg-rose-500/10 border-rose-700/50"
      summary = "Volatilité et/ou activité extrême élevées : marché nerveux, dominé par le court terme."
    elsif score >= 1
      key = :transition
      label = "🟧 Marché en transition"
      badge_cls = "text-amber-200 bg-amber-500/10 border-amber-700/50"
      summary = "Agitation en baisse mais encore présente : sortie progressive d’une phase d’excès."
    else
      key = :mature
      label = "🟩 Marché mature"
      badge_cls = "text-emerald-200 bg-emerald-500/10 border-emerald-700/50"
      summary = "Volatilité contenue et faible activité extrême : contexte plus stable, long terme dominant."
    end

    facts = { vol_pct: v, whale_events: w, score: score }

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
