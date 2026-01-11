# app/helpers/true_flow_helper.rb
module TrueFlowHelper
  def weekly_trueflow_read(limit: 7)
    rows = ExchangeTrueFlow.order(day: :desc).limit(limit).to_a
    return nil if rows.empty?

    inflow  = rows.sum { |x| x.inflow_btc.to_d }
    outflow = rows.sum { |x| x.outflow_btc.to_d }
    net     = inflow - outflow

    red   = rows.count { |x| x.status.to_s == "red" }
    amber = rows.count { |x| x.status.to_s == "amber" }
    green = rows.count { |x| x.status.to_s == "green" }

    score = (red * 2) + (amber * 1)

    regime =
      if score >= 6
        { label: "🔴 Régime vendeur", cls: "text-rose-300 bg-rose-500/10 border-rose-700/50", mood: "red" }
      elsif score >= 3
        { label: "🟡 Pression", cls: "text-amber-300 bg-amber-500/10 border-amber-700/50", mood: "amber" }
      else
        { label: "🟢 Normal", cls: "text-emerald-300 bg-emerald-500/10 border-emerald-700/50", mood: "green" }
      end

    net_cls =
      if net > 0
        "text-emerald-300"
      elsif net < 0
        "text-rose-300"
      else
        "text-gray-200"
      end

    net_label =
      if net > 0
        "Sur 7j, les exchanges reçoivent net"
      elsif net < 0
        "Sur 7j, les exchanges distribuent net"
      else
        "Sur 7j, équilibre"
      end

    hint =
      if score >= 6
        "Score élevé → pression vendeuse potentielle persistante (dépôts élevés plusieurs jours)."
      elsif score >= 3
        "Score moyen → marché sous pression (mix de jours 🟡/🔴)."
      else
        "Score faible → flux plutôt normaux sur la semaine."
      end

    ctx  = "Weekly TrueFlow (7j): inflow #{inflow.to_f.round(2)} BTC • outflow #{outflow.to_f.round(2)} BTC • net #{net.to_f.round(2)} BTC • score #{score} (red=#{red}, amber=#{amber}, green=#{green})"
    tags = "trueflow,exchange,weekly,regime"
    body = "Faits:\n#{ctx}\n\nLecture:\n#{hint}\n\nDécision:\n\nRisque / invalidation:\n"

    {
      rows: rows,
      inflow: inflow,
      outflow: outflow,
      net: net,
      red: red,
      amber: amber,
      green: green,
      score: score,
      regime: regime,
      net_cls: net_cls,
      net_label: net_label,
      hint: hint,
      ctx: ctx,
      tags: tags,
      body: body
    }
  end
end
