# frozen_string_literal: true

module DecisionEngine
  class SellNowScore
    def self.call(market_snapshot:, zones: nil, flow: nil, sell_now:, points: nil)
      new(
        market_snapshot: market_snapshot,
        zones: zones,
        flow: flow,
        sell_now: sell_now,
        points: points
      ).call
    end

    def initialize(market_snapshot:, zones:, flow:, sell_now:, points:)
      @s = market_snapshot
      @zones = zones
      @flow = flow
      @sell_now = sell_now
      @points = points
    end

    def call
      return no_data("market_snapshot manquant") unless @s.present?
      return no_data("sell_now manquant") unless @sell_now.present?

      pnl_pct = fetch(@sell_now, :pnl_pct).to_f

      net_usd =
        fetch(@sell_now, :sell_net_usd) ||
        fetch(@sell_now, :sell_net) ||
        fetch(@sell_now, :net_usd)

      net_usd = net_usd.to_f

      price_now =
        fetch(@sell_now, :price_now_usd) ||
        fetch(@sell_now, :price_usd) ||
        fetch(@sell_now, :sell_price) ||
        fetch(@sell_now, :price)

      price_now = price_now.to_f

      score = 50
      reasons = []
      warnings = []

      risk_level = @s.risk_level.to_s.presence || "medium"

      # =========================================================
      # 1) Profit / perte (base)
      # =========================================================
      if pnl_pct >= 8
        score += 18
        reasons << reason("profit_big", "Profit significatif (prendre une partie)", +18)
      elsif pnl_pct >= 3
        score += 8
        reasons << reason("profit_ok", "Profit correct (prise partielle possible)", +8)
      elsif pnl_pct > 0
        score += 3
        reasons << reason("profit_small", "Profit modéré (pas d’urgence)", +3)
      elsif pnl_pct <= -6
        score += 10
        reasons << reason("loss_cut", "Perte importante (couper le risque)", +10)
      elsif pnl_pct < 0
        score += 3
        reasons << reason("loss_small", "Légère perte (réévaluer)", +3)
      else
        reasons << reason("flat", "Position proche du break-even", +0)
      end

      # =========================================================
      # 1bis) Trailing adaptatif (drawdown depuis le pic)
      # =========================================================
      trailing = trailing_payload(pnl_now: pnl_pct, points: @points)
      if trailing
        dd       = trailing[:drawdown_from_peak_pct].to_f
        peak     = trailing[:peak_pnl_pct].to_f
        peak_day = trailing[:peak_day].to_s

        cfg = trailing_thresholds(risk_level)

        if peak >= cfg[:strong_peak] && dd >= cfg[:strong_dd]
          score += 16
          reasons << reason("trailing_strong", "Repli de #{dd.round(2)}% depuis le pic (#{peak.round(2)}% le #{peak_day}) → sécuriser", +16)
        elsif peak >= cfg[:mid_peak] && dd >= cfg[:mid_dd]
          score += 10
          reasons << reason("trailing", "Repli de #{dd.round(2)}% depuis le pic (#{peak.round(2)}% le #{peak_day}) → prudence", +10)
        elsif peak >= cfg[:light_peak] && dd >= cfg[:light_dd]
          score += 6
          reasons << reason("trailing_light", "Repli depuis le meilleur point → surveiller", +6)
        end
      end

      # =========================================================
      # 2) Risk level
      # =========================================================
      case risk_level
      when "high"
        score += 10
        reasons << reason("risk_high", "Risque élevé (prendre des profits / réduire)", +10)
      when "low"
        score -= 6
        reasons << reason("risk_low", "Risque faible (tenir est acceptable)", -6)
      end

      # =========================================================
      # 3) Zones + distances (utile pour le plan)
      # =========================================================
      next_levels = {}
      dist_sup_pct = nil
      dist_res_pct = nil

      if @zones.present? && price_now > 0
        res = @zones[:resistance]
        sup = @zones[:support]

        if sup
          sup_mid = (sup.low_usd.to_f + sup.high_usd.to_f) / 2.0
          dist_sup_pct = ((sup_mid - price_now) / price_now) * 100.0 # négatif si support sous le prix
          next_levels[:support_mid] = sup_mid
          next_levels[:support_dist_pct] = dist_sup_pct
        end

        if res
          res_mid = (res.low_usd.to_f + res.high_usd.to_f) / 2.0
          dist_res_pct = ((res_mid - price_now) / price_now) * 100.0 # positif si résistance au-dessus
          next_levels[:resistance_mid] = res_mid
          next_levels[:resistance_dist_pct] = dist_res_pct
        end

        # impacts “proximité” (comme avant)
        if res && dist_res_pct && dist_res_pct <= 3
          score += 10
          reasons << reason("near_resistance", "Proche d’une résistance (risque de rejet)", +10)
        end

        if sup && dist_sup_pct && dist_sup_pct >= -3
          score -= 6
          reasons << reason("near_support", "Proche d’un support (moins urgent de vendre)", -6)
        end
      end

      # =========================================================
      # 4) Flow
      # =========================================================
      if @flow.present? && @flow.respond_to?(:netflow_btc) && @flow.netflow_btc.present?
        nf = @flow.netflow_btc.to_f
        if nf > 0
          score += 6
          reasons << reason("netflow_pos", "Netflow positif vers exchanges (pression vendeuse)", +6)
        elsif nf < 0
          score -= 4
          reasons << reason("netflow_neg", "Netflow négatif (moins de pression vendeuse)", -4)
        end
      end

      # =========================================================
      # Clamp + action + suggestion
      # =========================================================
      score = [[score, 0].max, 100].min

      action =
        if score >= 70
          "sell"
        elsif score <= 40
          "hold"
        else
          "neutral"
        end

      suggestion, suggestion_label =
        if score >= 85
          ["sell_all", "Vendre 100% (sortie)"]
        elsif score >= 75
          ["take_profit_50", "Prendre profit 50%"]
        elsif score >= 70
          ["take_profit_25", "Prendre profit 25%"]
        else
          ["hold", "Conserver"]
        end

      confidence = reasons.size >= 3 ? "medium" : "low"

      plan = build_plan(
        action: action,
        pnl_pct: pnl_pct,
        trailing: trailing,
        dist_sup_pct: dist_sup_pct,
        dist_res_pct: dist_res_pct,
        next_levels: next_levels,
        risk_level: risk_level
      )

      {
        action: action,
        score: score,
        confidence: confidence,
        reasons: reasons.sort_by { |r| -r[:impact].to_i }.first(8),
        warnings: warnings.first(3),
        pnl_pct: pnl_pct,
        net_usd: net_usd,
        trailing: trailing,
        suggestion: suggestion,
        suggestion_label: suggestion_label,
        plan: plan,
        next_levels: next_levels
      }
    end

    private

    # -------- Plan SELL (quoi faire) --------
    def build_plan(action:, pnl_pct:, trailing:, dist_sup_pct:, dist_res_pct:, next_levels:, risk_level:)
      sup = next_levels[:support_mid]
      res = next_levels[:resistance_mid]

      # SELL: actionnable (partial / full)
      if action == "sell"
        if trailing.present?
          dd = trailing[:drawdown_from_peak_pct].to_f
          peak = trailing[:peak_pnl_pct].to_f
          if peak >= 5 && dd >= 2
            return "Sécuriser après retracement : vendre une partie maintenant, puis laisser un reste avec objectif/stop."
          end
        end

        if dist_res_pct && dist_res_pct <= 3
          return "Sous résistance : prendre profit maintenant (au moins partiel). Rebuy éventuel plus bas (support) ou sur cassure confirmée."
        end

        return "Setup de vente favorable : prendre profit (partiel ou total selon ta stratégie)."
      end

      # NEUTRAL: guidelines
      if action == "neutral"
        if trailing.present?
          dd = trailing[:drawdown_from_peak_pct].to_f
          if dd >= 2
            return "Zone de prudence : possible prise partielle, sinon attendre confirmation (rebond) ou invalider sous un niveau."
          end
        end

        if dist_res_pct && dist_res_pct <= 3
          return "Proche résistance : surveiller réaction. Vendre si rejet, sinon attendre une cassure/retour confirmé."
        end

        if dist_sup_pct && dist_sup_pct >= -3
          return "Proche support : vendre moins urgent. Surveiller si le support casse."
        end

        return "Pas de signal fort : conserver et réévaluer demain (flow + niveaux)."
      end

      # HOLD
      if action == "hold"
        if pnl_pct <= 0
          return "Pas de profit clair : éviter de vendre (sauf si risque ↑). Réévaluer avec stop/invalidations."
        end

        if risk_level == "low"
          return "Contexte plutôt sain : tenir et laisser respirer, surveiller résistance et netflow."
        end

        return "Tenir : vente non prioritaire. Réévaluer si approche résistance ou si flow devient défavorable."
      end

      nil
    end

    def trailing_thresholds(risk_level)
      case risk_level.to_s
      when "high"
        { strong_peak: 6.0, strong_dd: 2.5, mid_peak: 4.5, mid_dd: 1.8, light_peak: 3.0, light_dd: 1.5 }
      when "low"
        { strong_peak: 10.0, strong_dd: 4.0, mid_peak: 6.0, mid_dd: 2.5, light_peak: 4.0, light_dd: 2.0 }
      else
        { strong_peak: 8.0, strong_dd: 3.0, mid_peak: 5.0, mid_dd: 2.0, light_peak: 3.0, light_dd: 2.0 }
      end
    end

    def trailing_payload(pnl_now:, points:)
      pts = Array(points)
      return nil if pts.empty?

      peak = pts.max_by { |p| p.pnl_pct.to_f }
      return nil unless peak

      peak_pnl = peak.pnl_pct.to_f
      dd = (peak_pnl - pnl_now)

      { peak_day: peak.day, peak_pnl_pct: peak_pnl, drawdown_from_peak_pct: dd }
    end

    def fetch(obj, key)
      return nil if obj.nil?
      return obj.public_send(key) if obj.respond_to?(key)
      return obj[key] if obj.is_a?(Hash) && obj.key?(key)
      return obj[key.to_s] if obj.is_a?(Hash) && obj.key?(key.to_s)
      nil
    end

    def reason(key, label, impact)
      { key: key, label: label, impact: impact }
    end

    def no_data(msg)
      {
        action: "no_data",
        score: 0,
        confidence: "low",
        reasons: [{ key: "no_data", label: "Pas assez de données (#{msg})", impact: 0 }],
        warnings: [],
        plan: nil,
        next_levels: {}
      }
    end
  end
end
