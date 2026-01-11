# app/services/trader_alerts.rb
class TraderAlerts
  Alert = Struct.new(:level, :title, :message, :hint, keyword_init: true)

  # level: :critical / :warning / :info
  def self.for_market(price_metrics:, alignment:)
    alerts = []

    pos = price_metrics[:pos_pct]
    vol = price_metrics[:vol_pct]
    dd  = price_metrics[:max_drawdown_pct]
    perf = price_metrics[:perf_pct]

    status = alignment&.status
    net_btc = alignment&.flow_net_btc.to_f

    # --- High risk: rally fragile near top + high vol + exchange deposits ---
    if status == "divergence" && perf.to_f > 0 && pos.to_i >= 70 && vol.to_f >= 3.0 && net_btc > 0
      alerts << Alert.new(
        level: :critical,
        title: "Rally fragile (divergence + dépôts exchanges)",
        message: "Prix en hausse proche du haut de range, volatilité élevée et dépôts nets vers exchanges.",
        hint: "Réduire le risque (taille, levier), éviter de poursuivre, attendre confirmation/rejet."
      )
    end

    # --- Possible accumulation: price weak but net outflow ---
    if status == "divergence" && perf.to_f < 0 && net_btc < 0
      alerts << Alert.new(
        level: :warning,
        title: "Divergence (accumulation possible)",
        message: "Prix en baisse alors que les retraits nets dominent (raréfaction).",
        hint: "Surveiller un retournement sur support / cassure de structure avant d’entrer."
      )
    end

    # --- Trend supported (positive) ---
    if status == "supported" && perf.to_f > 0 && net_btc < 0
      alerts << Alert.new(
        level: :info,
        title: "Hausse plutôt soutenue",
        message: "Prix en hausse + retraits nets des exchanges.",
        hint: "Préférer achats sur repli plutôt que breakout tardif."
      )
    end

    # --- Risk control: drawdown already large ---
    if dd.present? && dd.to_f <= -12.0
      alerts << Alert.new(
        level: :warning,
        title: "Drawdown significatif",
        message: "La période a déjà subi une chute maximale importante.",
        hint: "Réduire la taille / attendre baisse de volatilité / invalider clairement."
      )
    end

    # --- Whipsaw zone: very high vol ---
    if vol.present? && vol.to_f >= 5.0
      alerts << Alert.new(
        level: :warning,
        title: "Volatilité très élevée",
        message: "Risque de mèches et faux signaux plus élevé que la normale.",
        hint: "Élargir les stops ou réduire la taille. Éviter l’overtrade."
      )
    end

    alerts
  end
end
