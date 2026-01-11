# frozen_string_literal: true

# app/controllers/market_controller.rb
class MarketController < ApplicationController
  def price
    # ---- Params ----
    @range = params[:range].presence_in(%w[7d 30d 1y]) || "30d"
    @alerts_mode = params[:alerts_mode].presence_in(%w[normal strict]) || "strict"

    days =
      case @range
      when "7d"  then 7
      when "30d" then 30
      else 365
      end

    # toggles séries (comma-separated)
    @show_series = parse_show_series(params[:show])

    # ---- Snapshot macro (déjà calculé via cron) ----
    @snapshot = MarketSnapshot.order(computed_at: :desc).first

    # ---- Fenêtre daily: J-1 (bougie du jour pas stable) ----
    from_day = days.days.ago.to_date
    to_day   = Date.current - 1

    # ---- Prix OHLC (USD) depuis la DB (composite en priorité) ----
    rows = BtcPriceDay
      .where(day: from_day..to_day)
      .where.not(close_usd: nil)
      .order(:day)
      .pluck(:day, :open_usd, :high_usd, :low_usd, :close_usd, :source)

    composite_rows = rows.select { |(_d, _o, _h, _l, _c, src)| src.to_s == "composite" }
    chosen_rows = composite_rows.any? ? composite_rows : rows

    @price_points = chosen_rows.map do |d, _o, _h, _l, c, _src|
      [d.strftime("%Y-%m-%d"), c.to_f]
    end

    # close series "YYYY-MM-DD" => close
    @series = chosen_rows.to_h { |d, _o, _h, _l, c, _src| [d.strftime("%Y-%m-%d"), c.to_f] }
    @price_series = @series

    # candles for Chart.js financial
    @candles = chosen_rows.map do |d, o, h, l, c, src|
      {
        x: d.strftime("%Y-%m-%d"),
        o: o.to_f,
        h: h.to_f,
        l: l.to_f,
        c: c.to_f,
        source: src.to_s
      }
    end

    # ---- True Exchange Flow (même période) ----
    flow_rows = ExchangeTrueFlow
      .where(day: from_day..to_day)
      .order(:day)
      .pluck(:day, :inflow_btc, :outflow_btc, :netflow_btc)

    flow_by_day = {}
    flow_rows.each do |d, inflow, outflow, net|
      k = d.strftime("%Y-%m-%d")
      flow_by_day[k] = {
        inflow: inflow.to_f,
        outflow: outflow.to_f,
        netflow: net.to_f
      }
    end

    # flows alignés sur les jours des bougies (référence principale)
    candle_days = @candles.map { |c| c[:x] }
    @flows = candle_days.map do |k|
      f = flow_by_day[k] || { inflow: 0.0, outflow: 0.0, netflow: 0.0 }
      { x: k, inflow: f[:inflow], outflow: f[:outflow], netflow: f[:netflow] }
    end

    # ---- Métriques période (sur close) ----
    values = @series.values.map(&:to_f)

    if values.size >= 2
      first = values.first
      last  = values.last

      @perf_pct = first.abs < 1e-12 ? 0.0 : (((last - first) / first) * 100).round(2)

      @high = values.max
      @low  = values.min

      range_val = (@high - @low)
      @pos_pct = range_val.abs < 1e-12 ? 50 : (((last - @low) / range_val) * 100).round

      peak = first
      max_dd = 0.0
      values.each do |v|
        peak = [peak, v].max
        next if peak <= 0
        dd = (v - peak) / peak.to_f * 100.0
        max_dd = [max_dd, dd].min
      end
      @max_drawdown_pct = max_dd.round(2)

      returns = values.each_cons(2).map do |a, b|
        next 0.0 if a.abs < 1e-12
        ((b - a) / a * 100.0).abs
      end
      @vol_pct = returns.empty? ? 0.0 : (returns.sum / returns.size.to_f).round(2)
      @vol_label = @vol_pct >= 4.0 ? "Élevée" : (@vol_pct >= 2.0 ? "Moyenne" : "Faible")
    else
      @perf_pct = @high = @low = @pos_pct = @max_drawdown_pct = @vol_pct = nil
      @vol_label = nil
    end

    # ---- Alignement prix/flows (ton moteur existant) ----
    @alignment = PriceFlowAlignment.compute(days: days, price_series: @series)

    @trader_alerts = TraderAlerts.for_market(
      price_metrics: {
        perf_pct: @perf_pct,
        pos_pct: @pos_pct,
        vol_pct: @vol_pct,
        max_drawdown_pct: @max_drawdown_pct
      },
      alignment: @alignment
    )

    alerts_txt =
      if @trader_alerts.present?
        @trader_alerts.map do |a|
          "- (#{a.level.to_s.upcase}) #{a.title}\n  #{a.message}\n  Suggestion: #{a.hint}"
        end.join("\n")
      else
        "- Aucune alerte (mode #{@alerts_mode})"
      end

    @one_liner ||= nil

    @journal_body_all = <<~TXT
      Résumé:
      #{@one_liner}

      Métriques:
      - Période: #{@range}
      - Perf: #{@perf_pct}%
      - Position: #{@pos_pct}%
      - Volatilité: #{@vol_label} (~#{@vol_pct}%/j)
      - Max drawdown: #{@max_drawdown_pct}%

      Alignement Prix / Exchanges:
      - Verdict: #{@alignment&.label}
      - Net flow: #{@alignment&.flow_net_btc} BTC
      - Inflow: #{@alignment&.flow_inflow_btc} BTC
      - Outflow: #{@alignment&.flow_outflow_btc} BTC
      - Lecture: #{@alignment&.hint}

      Alertes:
      #{alerts_txt}

      Décision:

      Plan:

      Risque / invalidation:
    TXT

    # ---- Heuristique "ventes confirmées ?" ----
    flow_net = @alignment&.flow_net_btc.to_f
    flow_strong = (@alerts_mode == "strict" ? 400.0 : 200.0)

    if flow_net >= flow_strong
      if @perf_pct.to_f < -0.5
        @sell_verdict = ["✅ Ventes confirmées", "text-rose-200 bg-rose-500/10 border-rose-700/50",
                         "Dépôts nets vers exchanges + baisse du prix sur la période → offre > demande."]
      elsif @perf_pct.to_f > 0.5
        @sell_verdict = ["🟡 Distribution / absorption", "text-amber-200 bg-amber-500/10 border-amber-700/50",
                         "Dépôts nets vers exchanges mais prix en hausse → vendeurs présents, acheteurs absorbent."]
      else
        @sell_verdict = ["⚪ Pression vendeuse potentielle", "text-gray-200 bg-white/5 border-gray-600/60",
                         "Dépôts nets vers exchanges mais prix quasi stable → marché absorbe pour l’instant."]
      end
    else
      @sell_verdict = ["🟢 Pas de signal de vente massif", "text-emerald-200 bg-emerald-500/10 border-emerald-700/50",
                       "Pas de dépôts nets significatifs vers exchanges sur la période."]
    end

    # ---- Trend filter MA200 depuis snapshot ----
    if @snapshot&.ma200_usd.present? && @snapshot&.price_now_usd.present?
      @ma200 = @snapshot.ma200_usd.to_f
      @px_now = @snapshot.price_now_usd.to_f
      @px_vs_ma200_pct = (@snapshot.price_vs_ma200_pct || ((@px_now - @ma200) / @ma200 * 100)).to_f

      @ma_badge =
        if @px_vs_ma200_pct >= 0
          ["Au-dessus MA200", "bg-emerald-500/10 border-emerald-700/50 text-emerald-200"]
        else
          ["Sous MA200", "bg-rose-500/10 border-rose-700/50 text-rose-200"]
        end
    end
  end

  private

  # show= "price,inflow,outflow,netflow" etc
  def parse_show_series(raw)
    arr =
      raw.to_s.split(",")
         .map { |s| s.to_s.strip.downcase }
         .select(&:present?)
         .uniq

    arr = %w[price inflow] if arr.empty?
    arr |= ["price"]

    allowed = %w[price inflow outflow netflow]
    arr & allowed
  end
end
