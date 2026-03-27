# frozen_string_literal: true

# app/services/market_absorption_index.rb
#
# Objectif:
# - Qualifier la réaction du prix face aux flux (fenêtre glissante)
# - Absorption vs Distribution
# - Basé uniquement sur faits observés
#
class MarketAbsorptionIndex
  Result = Struct.new(
    :key,       # :absorption | :distribution | :neutral
    :label,
    :badge_cls,
    :summary,
    :window_days,
    :facts,
    keyword_init: true
  )

  def self.call(
    window_days: 30,
    netflow_btc: nil,
    perf_pct: nil
  )
    net  = netflow_btc&.to_f
    perf = perf_pct&.to_f

    net_min   = 1000.0  # BTC sur la fenêtre
    perf_flat = 1.0     # %

    if net && net > net_min
      if perf && perf >= perf_flat
        key = :absorption
        label = "🟩 Absorption"
        badge_cls = "text-emerald-200 bg-emerald-500/10 border-emerald-700/50"
        summary = "Pression vendeuse potentielle absorbée : le prix tient malgré les dépôts vers exchanges."
      elsif perf && perf <= -perf_flat
        key = :distribution
        label = "🟥 Distribution"
        badge_cls = "text-rose-200 bg-rose-500/10 border-rose-700/50"
        summary = "Pression vendeuse non absorbée : les dépôts vers exchanges s’accompagnent d’une baisse du prix."
      else
        key = :neutral
        label = "⚪ Équilibre instable"
        badge_cls = "text-gray-200 bg-white/5 border-gray-600/60"
        summary = "Flux présents mais réaction du prix limitée : phase d’hésitation."
      end
    else
      key = :neutral
      label = "⚪ Neutre"
      badge_cls = "text-gray-200 bg-white/5 border-gray-600/60"
      summary = "Flux faibles vers exchanges : pas de signal clair d’absorption ou de distribution."
    end

    Result.new(
      key: key,
      label: label,
      badge_cls: badge_cls,
      summary: summary,
      window_days: window_days,
      facts: { netflow_btc: net, perf_pct: perf }
    )
  end
end
