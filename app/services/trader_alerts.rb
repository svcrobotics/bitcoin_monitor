# app/services/trader_alerts.rb
class TraderAlerts
  Alert = Struct.new(:level, :title, :message, :hint, :trigger, :values, keyword_init: true)

  # level: :critical / :warning / :info
  # values: hash des valeurs mesurées (ex: { "Max DD" => "-26.5%", "Vol" => "5.2%/j" })
  def self.for_market(price_metrics:, alignment:)
    alerts = []

    pos  = price_metrics[:pos_pct]
    vol  = price_metrics[:vol_pct]
    dd   = price_metrics[:max_drawdown_pct]
    perf = price_metrics[:perf_pct]

    status  = alignment&.status
    net_btc = alignment&.flow_net_btc

    # Helpers format
    fmt_pct = ->(v, p = 1) { v.nil? ? "—" : "#{v.to_f.round(p)}%" }
    fmt_pct_signed = ->(v, p = 1) do
      return "—" if v.nil?
      x = v.to_f
      "#{x.positive? ? "+" : ""}#{x.round(p)}%"
    end
    fmt_btc_signed = ->(v, p = 2) do
      return "—" if v.nil?
      x = v.to_f
      "#{x.positive? ? "+" : ""}#{format("%.#{p}f", x)} BTC"
    end

    # --- High risk: rally fragile near top + high vol + exchange deposits ---
    if status == "divergence" && perf.to_f > 0 && pos.to_i >= 70 && vol.to_f >= 3.0 && net_btc.to_f > 0
      alerts << Alert.new(
        level: :critical,
        title: "Rally fragile (divergence + dépôts exchanges)",
        message: "Prix en hausse proche du haut de range, volatilité élevée et dépôts nets vers exchanges.",
        hint: "Réduire le risque (taille, levier), éviter de poursuivre, attendre confirmation/rejet.",
        trigger: "divergence & perf>0 & pos≥70 & vol≥3.0 & netflow>0",
        values: {
          "Status"   => status.to_s,
          "Perf"     => fmt_pct_signed.call(perf, 2),
          "Position" => "#{pos.to_f.round(0)}%",
          "Vol"      => "#{vol.to_f.round(2)}%/j",
          "NetFlow"  => fmt_btc_signed.call(net_btc, 2)
        }
      )
    end

    # --- Possible accumulation: price weak but net outflow ---
    if status == "divergence" && perf.to_f < 0 && net_btc.to_f < 0
      alerts << Alert.new(
        level: :warning,
        title: "Divergence (accumulation possible)",
        message: "Prix en baisse alors que les retraits nets dominent (raréfaction).",
        hint: "Surveiller un retournement sur support / cassure de structure avant d’entrer.",
        trigger: "divergence & perf<0 & netflow<0",
        values: {
          "Status"  => status.to_s,
          "Perf"    => fmt_pct_signed.call(perf, 2),
          "NetFlow" => fmt_btc_signed.call(net_btc, 2)
        }
      )
    end

    # --- Trend supported (positive) ---
    if status == "supported" && perf.to_f > 0 && net_btc.to_f < 0
      alerts << Alert.new(
        level: :info,
        title: "Hausse plutôt soutenue",
        message: "Prix en hausse + retraits nets des exchanges.",
        hint: "Préférer achats sur repli plutôt que breakout tardif.",
        trigger: "supported & perf>0 & netflow<0",
        values: {
          "Status"  => status.to_s,
          "Perf"    => fmt_pct_signed.call(perf, 2),
          "NetFlow" => fmt_btc_signed.call(net_btc, 2)
        }
      )
    end

    # --- Risk control: drawdown already large ---
    if dd.present? && dd.to_f <= -12.0
      alerts << Alert.new(
        level: :warning,
        title: "Drawdown significatif",
        message: "La période a déjà subi une chute maximale importante.",
        hint: "Réduire la taille / attendre baisse de volatilité / invalider clairement.",
        trigger: "max_drawdown ≤ -12.0%",
        values: {
          "Max DD" => fmt_pct.call(dd, 1),
          "Perf"   => fmt_pct_signed.call(perf, 2),
          "Vol"    => vol.present? ? "#{vol.to_f.round(2)}%/j" : "—"
        }
      )
    end

    # --- Whipsaw zone: very high vol ---
    if vol.present? && vol.to_f >= 5.0
      alerts << Alert.new(
        level: :warning,
        title: "Volatilité très élevée",
        message: "Risque de mèches et faux signaux plus élevé que la normale.",
        hint: "Élargir les stops ou réduire la taille. Éviter l’overtrade.",
        trigger: "vol ≥ 5.0%/j",
        values: {
          "Vol"  => "#{vol.to_f.round(2)}%/j",
          "Perf" => fmt_pct_signed.call(perf, 2),
          "Max DD" => dd.present? ? fmt_pct.call(dd, 1) : "—"
        }
      )
    end

    alerts
  end
end
