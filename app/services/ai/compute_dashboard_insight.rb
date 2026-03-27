# frozen_string_literal: true
require "digest"
require "json"

module Ai
  # Daily neutral market analysis for the dashboard (desk-analyst tone).
  #
  # - No buy/sell advice. No scoring. No imperatives.
  # - Output is neutral: regime, drivers, levels, scenarios, risk.
  # - Daily cadence with short-term (7d) and broader (30d) context.
  #
  # Inputs:
  # - as_of_day: Date (or YYYY-MM-DD)
  # - market_snapshot:
  # - price_now: numeric
  # - price_zones: {support:, resistance:, bonus:[]}
  # - series_7d / series_30d: [{day:, open:, high:, low:, close:}] (close is required)
  class ComputeDashboardInsight
    KEY = "dashboard_market_daily_neutral"

    def call(
      as_of_day:,
      market_snapshot:,
      price_now:,
      price_zones:,
      series_7d: nil,
      series_30d: nil
    )
      as_of_day = as_of_day.to_s

      s7  = series_payload(series_7d, limit: 7)
      s30 = series_payload(series_30d, limit: 30)

      stats7  = series_stats(s7)
      stats30 = series_stats(s30)

      payload_input = {
        as_of_day: as_of_day,
        price_now_usd: round_usd(price_now),
        market_snapshot: snapshot_payload(market_snapshot),
        zones: zones_payload(price_zones),
        series_7d: s7,
        series_30d: s30,
        stats_7d: stats7,
        stats_30d: stats30
      }

      input_digest = Digest::SHA256.hexdigest(payload_input.to_json)

      cached = AiInsight
        .where(key: KEY, input_digest: input_digest)
        .order(created_at: :desc)
        .first

      if cached.present?
        begin
          parsed = JSON.parse(cached.content)
          return parsed if parsed.is_a?(Hash)
        rescue JSON::ParserError
          # ignore and regenerate
        end
      end

      payload = OpenaiClient.new.json_response!(
        schema_name: "dashboard_market_daily_neutral",
        input: prompt(payload_input)
      )

      AiInsight.create!(
        key: KEY,
        input_digest: input_digest,
        provider: "openai",
        model: "gpt-4.1-mini",
        content: payload.to_json,
        meta: {
          payload: payload,
          as_of_day: as_of_day,
          price_now: price_now.to_f,
          generated_at: Time.current
        }
      )

      payload
    end

    private

    # ----------------------------
    # Formatting helpers
    # ----------------------------

    def round_usd(x)
      x.to_f.round(0)
    end

    def round_pct(x)
      x.to_f.round(2)
    end

    # ----------------------------
    # Snapshot / Zones
    # ----------------------------

    def snapshot_payload(s)
      return {} unless s

      {
        market_bias: s.market_bias.to_s,
        cycle_zone: s.cycle_zone.to_s,
        risk_level: s.risk_level.to_s,
        ma200_usd: round_usd(s.ma200_usd),
        price_vs_ma200_pct: round_pct(s.price_vs_ma200_pct),
        drawdown_pct: round_pct(s.drawdown_pct),
        amplitude_30d_pct: round_pct(s.amplitude_30d_pct),
        reasons: Array(s.reasons).map(&:to_s)
      }
    end

    def zones_payload(z)
      return {} unless z

      sup = z[:support] || z["support"]
      res = z[:resistance] || z["resistance"]
      bonus = z[:bonus] || z["bonus"]

      {
        support: zone_payload(sup),
        resistance: zone_payload(res),
        bonus: Array(bonus).map { |b| bonus_zone_payload(b) }
      }
    end

    def zone_payload(zone)
      return nil unless zone

      low =
        if zone.respond_to?(:low_usd) then zone.low_usd
        else zone[:low_usd] || zone["low_usd"] || zone[:low] || zone["low"]
        end

      high =
        if zone.respond_to?(:high_usd) then zone.high_usd
        else zone[:high_usd] || zone["high_usd"] || zone[:high] || zone["high"]
        end

      strength =
        if zone.respond_to?(:strength) then zone.strength
        else zone[:strength] || zone["strength"]
        end

      touches =
        if zone.respond_to?(:touches_count) then zone.touches_count
        else zone[:touches] || zone["touches"] || zone[:touches_count] || zone["touches_count"]
        end

      {
        low: round_usd(low),
        high: round_usd(high),
        strength: strength.to_s,
        touches: touches.to_i
      }
    end

    def bonus_zone_payload(b)
      return {} unless b

      if b.respond_to?(:kind)
        {
          kind: b.kind.to_s,
          low: round_usd(b.respond_to?(:low_usd) ? b.low_usd : nil),
          high: round_usd(b.respond_to?(:high_usd) ? b.high_usd : nil),
          strength: (b.respond_to?(:strength) ? b.strength : "").to_s
        }
      else
        bb = b.is_a?(Hash) ? b : {}
        {
          kind: (bb[:kind] || bb["kind"]).to_s,
          low: round_usd(bb[:low_usd] || bb["low_usd"] || bb[:low] || bb["low"]),
          high: round_usd(bb[:high_usd] || bb["high_usd"] || bb[:high] || bb["high"]),
          strength: (bb[:strength] || bb["strength"]).to_s
        }
      end
    end

    # ----------------------------
    # Series (compact) + stats
    # ----------------------------

    # Keep compact to avoid token bloat.
    # Candle payload keys: day,o,h,l,c (USD)
    def series_payload(series, limit:)
      arr = Array(series).compact
      return [] if arr.empty?

      arr.first(limit).map { |c| candle_payload(c) }.compact
    end

    def candle_payload(c)
      day =
        if c.respond_to?(:day) then c.day
        else c[:day] || c["day"] || c[:date] || c["date"]
        end

      close =
        if c.respond_to?(:close) then c.close
        else c[:close] || c["close"]
        end

      return nil if day.blank? || close.blank?

      open_ =
        if c.respond_to?(:open) then c.open
        else c[:open] || c["open"]
        end

      high =
        if c.respond_to?(:high) then c.high
        else c[:high] || c["high"]
        end

      low =
        if c.respond_to?(:low) then c.low
        else c[:low] || c["low"]
        end

      {
        day: day.to_s,
        o: open_.present? ? round_usd(open_) : nil,
        h: high.present? ? round_usd(high) : nil,
        l: low.present? ? round_usd(low) : nil,
        c: round_usd(close)
      }
    end

    # Provide computable facts to reduce model improvisation.
    def series_stats(series)
      series = Array(series)
      return {} if series.size < 2

      closes = series.map { |x| x[:c].to_f }.reject(&:zero?)
      return {} if closes.size < 2

      first = closes.first
      last  = closes.last
      high  = closes.max
      low   = closes.min

      perf_pct = first.zero? ? nil : ((last - first) / first * 100.0)

      # simple daily return volatility (std dev in %)
      rets = []
      closes.each_cons(2) do |a, b|
        next if a.to_f.zero?
        rets << ((b - a) / a * 100.0)
      end

      vol = nil
      if rets.any?
        mean = rets.sum / rets.size
        var = rets.map { |r| (r - mean) ** 2 }.sum / rets.size
        vol = Math.sqrt(var)
      end

      {
        points: series.size,
        first_close: round_usd(first),
        last_close: round_usd(last),
        high_close: round_usd(high),
        low_close: round_usd(low),
        perf_pct: perf_pct.nil? ? nil : round_pct(perf_pct),
        vol_pct: vol.nil? ? nil : round_pct(vol)
      }
    end

    # ----------------------------
    # Prompt
    # ----------------------------

    def prompt(input_hash)
      <<~PROMPT
      Tu es un analyste Bitcoin (desk).
      Tu dois produire une analyse NEUTRE, JOURNALIÈRE, STRICTEMENT en JSON (aucun texte hors JSON).

      Interdits :
      - Aucun conseil (pas de BUY/SELL/HOLD).
      - Pas de scoring d’action.
      - Pas d’explications macro génériques (ex: "facteurs économiques externes", "incertitude globale crypto") sauf si ces facteurs apparaissent dans les données d’entrée (ce n’est pas le cas ici).

      Données (entrée) :
      #{input_hash.to_json}

      Règles :
      - Vocabulaire pro, phrases courtes (desk note). Zéro pédagogie.
      - Utiliser STRICTEMENT "support" et "résistance" (jamais "soutien").
      - Ne jamais inventer de chiffres : n’utiliser que les valeurs fournies (market_snapshot, stats_7d/30d, series, levels).
      - "drivers" = constats observables (3–5 items), basés sur les données d’entrée.
      - "weekly"/"monthly" : résumer la dynamique à partir de stats_7d/stats_30d + market_snapshot (1 phrase max par summary).
      - "scenarios" : 2–3, toujours avec invalidation explicite (niveau/condition).
      - MA200 : si mentionnée, afficher à l’unité (pas de décimales).
      - Disclaimer : 1 seule fois, formulation courte.

      Sortie JSON attendue (structure OBLIGATOIRE) :
      {
        "as_of_day": "YYYY-MM-DD",
        "headline": "...",
        "regime": "...",
        "weekly": { "summary": "...", "drivers": ["..."] },
        "monthly": { "summary": "...", "drivers": ["..."] },
        "levels": {
          "support": { "low": 0, "high": 0, "strength": "...", "touches": 0 },
          "resistance": { "low": 0, "high": 0, "strength": "...", "touches": 0 },
          "bonus": [{ "kind": "...", "low": 0, "high": 0, "strength": "..." }]
        },
        "drivers": ["..."],
        "scenarios": [{ "if": "...", "then": "...", "invalidation": "..." }],
        "risk": ["..."],
        "disclaimer": "..."
      }

      Contraintes :
      - headline : 1 phrase max.
      - weekly.drivers / monthly.drivers : 2–4 items max.
      - drivers : 3–5 items max.
      - risk : 2–4 items max.
      PROMPT
    end
  end
end
