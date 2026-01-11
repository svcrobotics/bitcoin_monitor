# app/services/price_flow_alignment.rb
class PriceFlowAlignment
  Result = Struct.new(
    :days,
    :price_perf_pct,
    :flow_net_btc,
    :flow_inflow_btc,
    :flow_outflow_btc,
    :status,          # "supported" | "divergence" | "neutral"
    :label,           # texte court
    :hint,            # texte explicatif
    :badge_cls,       # classes tailwind
    keyword_init: true
  )

  # Ajuste ces seuils si tu veux réduire le bruit
  DEFAULT_PRICE_EPS_PCT = 0.5      # perf trop faible => neutre
  DEFAULT_FLOW_EPS_BTC  = 200.0    # net flow trop faible => neutre (à calibrer)

  def self.compute(days:, price_series:, flow_scope: ExchangeTrueFlow.all,
                   price_eps_pct: DEFAULT_PRICE_EPS_PCT, flow_eps_btc: DEFAULT_FLOW_EPS_BTC)
    values = price_series.values
    return Result.new(days: days, status: "neutral", label: "Neutre", hint: "Pas assez de données.") if values.size < 2

    first = values.first.to_f
    last  = values.last.to_f
    price_perf_pct = ((last - first) / first * 100.0).round(2)

    start_day = days.days.ago.to_date
    flows = flow_scope.where("day >= ?", start_day)

    inflow  = flows.sum(:inflow_btc).to_f
    outflow = flows.sum(:outflow_btc).to_f
    net     = (inflow - outflow)

    price_dir =
      if price_perf_pct.abs < price_eps_pct
        0
      else
        price_perf_pct.positive? ? 1 : -1
      end

    flow_dir =
      if net.abs < flow_eps_btc
        0
      else
        net.positive? ? 1 : -1
      end

    # Verdict
    status, label, hint, badge_cls =
      if price_dir == 0 || flow_dir == 0
        ["neutral", "⚪ Neutre", "Signal faible (prix et/ou flux trop petits sur la période).", "text-gray-200 bg-white/5 border-gray-600/60"]
      elsif price_dir == 1 && flow_dir == -1
        ["supported", "🟢 Soutenu", "Prix en hausse + retraits nets des exchanges → mouvement souvent plus “sain”.", "text-emerald-200 bg-emerald-500/10 border-emerald-700/50"]
      elsif price_dir == -1 && flow_dir == 1
        ["supported", "🟢 Soutenu", "Prix en baisse + dépôts nets vers exchanges → pression vendeuse cohérente.", "text-emerald-200 bg-emerald-500/10 border-emerald-700/50"]
      elsif price_dir == 1 && flow_dir == 1
        ["divergence", "🟡 Divergence", "Prix en hausse mais dépôts nets vers exchanges → rally potentiellement fragile (distribution).", "text-amber-200 bg-amber-500/10 border-amber-700/50"]
      else # price_dir == -1 && flow_dir == -1
        ["divergence", "🟡 Divergence", "Prix en baisse mais retraits nets → possible accumulation / vente absorbée.", "text-amber-200 bg-amber-500/10 border-amber-700/50"]
      end

    Result.new(
      days: days,
      price_perf_pct: price_perf_pct,
      flow_net_btc: net,
      flow_inflow_btc: inflow,
      flow_outflow_btc: outflow,
      status: status,
      label: label,
      hint: hint,
      badge_cls: badge_cls
    )
  end
end
