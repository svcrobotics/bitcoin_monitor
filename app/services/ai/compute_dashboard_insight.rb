# frozen_string_literal: true
require "digest"
require "json"

module Ai
  class ComputeDashboardInsight
    KEY = "dashboard_market"

    # buy_decision / sell_decision / sell_now sont optionnels (MVP friendly)
    def call(market_snapshot:, price_now:, price_zones:, buy_decision: nil, sell_decision: nil, sell_now: nil)
      input_digest = Digest::SHA256.hexdigest(
        {
          market_snapshot: snapshot_payload(market_snapshot),
          price_now: price_now.to_f,
          zones: zones_payload(price_zones),
          buy_decision: decision_payload(buy_decision),
          sell_decision: decision_payload(sell_decision),
          sell_now: sell_now_payload(sell_now)
        }.to_json
      )

      cached = AiInsight
        .where(key: KEY, input_digest: input_digest)
        .order(created_at: :desc)
        .first

      if cached.present?
        begin
          parsed = JSON.parse(cached.content)
          return parsed if parsed.is_a?(Hash)
        rescue JSON::ParserError
          # Cache invalide → on ignore et on régénère
        end
      end

      payload = OpenaiClient.new.json_response!(
        schema_name: "dashboard_market",
        input: prompt(
          market_snapshot: market_snapshot,
          price_now: price_now,
          price_zones: price_zones,
          buy_decision: buy_decision,
          sell_decision: sell_decision,
          sell_now: sell_now
        )
      )

      AiInsight.create!(
        key: KEY,
        input_digest: input_digest,
        provider: "openai",
        model: "gpt-4.1-mini",
        content: payload.to_json,
        meta: {
          payload: payload,
          price_now: price_now.to_f,
          generated_at: Time.current
        }
      )

      payload
    end

    private

    # ============================
    # PAYLOAD BUILDERS
    # ============================

    def snapshot_payload(s)
      return {} unless s

      {
        market_bias: s.market_bias,
        cycle_zone: s.cycle_zone,
        risk_level: s.risk_level,
        ma200_usd: s.ma200_usd,
        price_vs_ma200_pct: s.price_vs_ma200_pct,
        drawdown_pct: s.drawdown_pct,
        amplitude_30d_pct: s.amplitude_30d_pct,
        reasons: Array(s.reasons)
      }
    end

    def zones_payload(z)
      return {} unless z

      sup = z[:support]
      res = z[:resistance]

      {
        support: sup && {
          low: sup.low_usd.to_f,
          high: sup.high_usd.to_f,
          strength: sup.strength,
          touches: sup.touches_count
        },
        resistance: res && {
          low: res.low_usd.to_f,
          high: res.high_usd.to_f,
          strength: res.strength,
          touches: res.touches_count
        },
        bonus: Array(z[:bonus]).map do |b|
          {
            kind: b.kind,
            low: b.low_usd.to_f,
            high: b.high_usd.to_f,
            strength: b.strength
          }
        end
      }
    end

    # décision “engine-friendly”
    # attendu: { action:, score:, confidence:, reasons:[{label/why/impact}], warnings:[] }
    def decision_payload(d)
      return nil if d.blank?

      {
        action: d[:action] || d["action"],
        score: d[:score] || d["score"],
        confidence: d[:confidence] || d["confidence"],
        reasons: Array(d[:reasons] || d["reasons"]).map do |r|
          if r.is_a?(Hash)
            {
              key: r[:key] || r["key"],
              label: r[:label] || r["label"] || r[:why] || r["why"],
              impact: r[:impact] || r["impact"]
            }
          else
            { label: r.to_s }
          end
        end,
        warnings: Array(d[:warnings] || d["warnings"]).map(&:to_s)
      }
    end

    # sell_now: ton objet résultat "si je vends aujourd’hui" (net/pnl/as_of_day etc.)
    def sell_now_payload(s)
      return nil if s.blank?

      {
        as_of_day: (s.respond_to?(:as_of_day) ? s.as_of_day : (s[:as_of_day] || s["as_of_day"])).to_s,
        net_usd:   (s.respond_to?(:net) ? s.net : (s[:net] || s["net"] || s[:sell_net] || s["sell_net"])).to_f,
        pnl_usd:   (s.respond_to?(:pnl) ? s.pnl : (s[:pnl] || s["pnl"])).to_f,
        pnl_pct:   (s.respond_to?(:pnl_pct) ? s.pnl_pct : (s[:pnl_pct] || s["pnl_pct"])).to_f
      }
    end

    # ============================
    # PROMPT
    # ============================

    def prompt(market_snapshot:, price_now:, price_zones:, buy_decision:, sell_decision:, sell_now:)
      <<~PROMPT
      Tu es un analyste Bitcoin.
      Tu dois produire une analyse STRICTEMENT en JSON (aucun texte hors JSON).

      Deux audiences :
      - "simple" (grand public)
      - "trader" (avancé)

      Données marché :
      - price_now_usd: #{price_now.to_f}
      - market_snapshot: #{snapshot_payload(market_snapshot).to_json}
      - price_zones: #{zones_payload(price_zones).to_json}

      Données décision (optionnelles, si présentes) :
      - buy_decision: #{decision_payload(buy_decision).to_json}
      - sell_decision: #{decision_payload(sell_decision).to_json}
      - sell_now: #{sell_now_payload(sell_now).to_json}

      Règles :
      - "simple": vocabulaire clair, mais utiliser les termes financiers standards.
      - Utiliser STRICTEMENT "support" et "résistance" (jamais "soutien").
      - Expliquer ATH = "plus haut sur ~12 mois" si utilisé.
      - "trader" : MA200, drawdown, vol30, support/résistance acceptés.
      - Toujours rappeler "pas un conseil financier" (1 fois par audience).
      - Si buy_decision/sell_decision/sell_now sont présents, tu DOIS les résumer en 2-3 points maximum
        et mentionner score + action (ex: BUY/HOLD/AVOID).
      - Ne jamais inventer des chiffres absents des données.

      Sortie JSON attendue (structure OBLIGATOIRE) :
      {
        "simple": {
          "headline": "...",
          "bullets": ["..."],
          "what_to_watch": ["..."],
          "disclaimer": "...",
          "decision": {
            "buy": { "action": "...", "score": 0, "reasons": ["..."] },
            "sell": { "action": "...", "score": 0, "reasons": ["..."] },
            "sell_now": { "as_of_day": "...", "net_usd": 0, "pnl_usd": 0, "pnl_pct": 0 }
          }
        },
        "trader": {
          "regime": "...",
          "key_levels": {
            "support": {...},
            "resistance": {...}
          },
          "notes": ["..."],
          "scenarios": [
            { "if": "...", "then": "..." }
          ],
          "disclaimer": "...",
          "decision": {
            "buy": { "action": "...", "score": 0, "reasons": ["..."] },
            "sell": { "action": "...", "score": 0, "reasons": ["..."] },
            "sell_now": { "as_of_day": "...", "net_usd": 0, "pnl_usd": 0, "pnl_pct": 0 }
          }
        }
      }
      PROMPT
    end
  end
end
