# frozen_string_literal: true

module DecisionEngine
  class BuyNow
    def self.call(market_snapshot:, price_now:, zones: nil, flow: nil)
      new(
        market_snapshot: market_snapshot,
        price_now: price_now,
        zones: zones,
        flow: flow
      ).call
    end

    def initialize(market_snapshot:, price_now:, zones:, flow:)
      @s     = market_snapshot
      @price = price_now.to_f
      @zones = zones
      @flow  = flow
    end

    def call
      return no_data("market_snapshot manquant") unless @s.present?
      return no_data("price_now manquant") if @price <= 0

      score    = 50
      reasons  = []
      warnings = []

      risk_level = @s.risk_level.to_s.presence || "medium"

      # =========================================================
      # 1) Risk level
      # =========================================================
      case risk_level
      when "low"
        score += 18
        reasons << reason("risk_low", "Risque faible (contexte favorable)", +18)
      when "medium"
        reasons << reason("risk_med", "Risque modéré (prudence)", +0)
      when "high"
        score -= 18
        reasons << reason("risk_high", "Risque élevé (taille réduite / attendre)", -18)
      end

      # =========================================================
      # 2) Momentum via distance MA200 (simple mais lisible)
      # =========================================================
      pv = @s.price_vs_ma200_pct.to_f

      if pv <= -8
        score += 12
        reasons << reason("ma200_deep_below", "Prix nettement sous MA200 (zone value / risque baissier)", +12)
      elsif pv <= -5
        score += 10
        reasons << reason("below_ma200", "Prix sous MA200 (potentiel d’achat long terme)", +10)
      elsif pv >= 10
        score -= 12
        reasons << reason("ma200_overheat", "Prix très au-dessus de MA200 (sur-extension / acheter = moins bon)", -12)
      elsif pv >= 8
        score -= 10
        reasons << reason("above_ma200", "Prix au-dessus de MA200 (moins intéressant en achat)", -10)
      else
        reasons << reason("near_ma200", "Prix proche de la MA200 (momentum neutre)", +0)
      end

      # =========================================================
      # 3) Zones support / résistance + distances (audit)
      # =========================================================
      next_levels = {}
      dist_sup_pct = nil
      dist_res_pct = nil

      if @zones.present?
        sup = @zones[:support]
        res = @zones[:resistance]

        if sup
          sup_mid = (sup.low_usd.to_f + sup.high_usd.to_f) / 2.0
          next_levels[:support_mid] = sup_mid

          # négatif si support en dessous
          dist_sup_pct = ((sup_mid - @price) / @price) * 100.0
          next_levels[:support_dist_pct] = dist_sup_pct


          # support proche (<= 3% sous le prix) => bon timing relatif
          if dist_sup_pct >= -3
            score += 8
            reasons << reason("near_support", "Proche d’un support (bon timing relatif)", +8)
          end
        end

        if res
          res_mid = (res.low_usd.to_f + res.high_usd.to_f) / 2.0
          next_levels[:resistance_mid] = res_mid

          # positif si résistance au-dessus
          dist_res_pct = ((res_mid - @price) / @price) * 100.0
          next_levels[:resistance_dist_pct] = dist_res_pct


          # résistance proche (<= 3% au-dessus) => risqué d’acheter
          if dist_res_pct <= 3
            score -= 6
            reasons << reason("near_resistance", "Proche d’une résistance (risque de rejet)", -6)
          end
        end
      end

      # =========================================================
      # 4) Flow : netflow>0 = pression vendeuse potentielle
      # =========================================================
      if @flow.present? && @flow.respond_to?(:netflow_btc) && @flow.netflow_btc.present?
        nf = @flow.netflow_btc.to_f
        if nf > 0
          score -= 6
          warnings << "Netflow positif vers exchanges : pression vendeuse potentielle."
        elsif nf < 0
          score += 4
          reasons << reason("netflow_negative", "Netflow négatif (sorties exchanges)", +4)
        end
      end

      # =========================================================
      # Clamp + action + plan (quoi faire)
      # =========================================================
      score = [[score, 0].max, 100].min

      action =
        if score >= 70
          "buy"
        elsif score <= 40
          "avoid"
        else
          "hold"
        end

      confidence = reasons.size >= 3 ? "medium" : "low"

      plan = build_plan(
        action: action,
        pv: pv,
        dist_sup_pct: dist_sup_pct,
        dist_res_pct: dist_res_pct,
        next_levels: next_levels
      )

      {
        action: action,
        score: score,
        confidence: confidence,
        reasons: reasons.sort_by { |r| -r[:impact].to_i }.first(8),
        warnings: warnings.first(3),
        plan: plan,
        next_levels: next_levels
      }
    end

    private

    def build_plan(action:, pv:, dist_sup_pct:, dist_res_pct:, next_levels:)
      # MVP : un plan simple et actionnable
      if action == "buy"
        return "Conditions favorables : achat possible (idéalement proche support)."
      end

      if action == "avoid"
        # si résistance proche -> attendre pullback
        if dist_res_pct && dist_res_pct <= 3
          sup = next_levels[:support_mid]
          if sup
            return "Éviter d’acheter sous résistance. Attendre un repli vers le support (~#{sup.round(0)}$) ou une cassure confirmée."
          end
          return "Éviter d’acheter sous résistance. Attendre un repli ou une cassure confirmée."
        end

        # si momentum trop haut
        if pv >= 8
          return "Prix déjà étendu au-dessus de MA200 : attendre un repli / consolidation."
        end

        # si support loin
        if dist_sup_pct && dist_sup_pct <= -6
          return "Support assez loin : privilégier une entrée plus basse ou en DCA très léger."
        end

        return "Pas de setup clair : attendre une meilleure zone (support) ou un signal de force."
      end

      # hold
      if dist_sup_pct && dist_sup_pct >= -3
        return "Zone neutre : possible DCA léger près du support, sinon attendre confirmation."
      end

      "Zone neutre : attendre un meilleur prix (support) ou une confirmation haussière."
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
