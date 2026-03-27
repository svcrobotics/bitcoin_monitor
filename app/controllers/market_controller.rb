# frozen_string_literal: true

# app/controllers/market_controller.rb
class MarketController < ApplicationController
  def price
    allowed_ranges = %w[7d 30d 1y].freeze

    # ------------------------------------------------------------------
    # 1) Range selection:
    #    - if params[:range] is present and valid -> use it and persist
    #    - else, if params[:days] is present -> map to a range (7d/30d/1y)
    #    - else -> session -> default "30d"
    # ------------------------------------------------------------------

    if params[:range].present? && allowed_ranges.include?(params[:range])
      session[:market_range] = params[:range]
    elsif params[:days].present?
      # allow old links like ?days=365
      days_i = params[:days].to_i
      mapped =
        if days_i >= 365
          "1y"
        elsif days_i >= 30
          "30d"
        else
          "7d"
        end
      session[:market_range] = mapped
    end

    @range =
      params[:range].presence_in(allowed_ranges) ||
      session[:market_range].to_s.presence_in(allowed_ranges) ||
      "30d"

    # Days window (from range)
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
    to_day   = Date.current - 1
    from_day = to_day - (days - 1)

    # ---- Prix OHLC (USD) depuis la DB (composite en priorité) ----
    rows = BtcPriceDay
      .where(day: from_day..to_day)
      .where.not(close_usd: nil)
      .order(:day)
      .pluck(:day, :open_usd, :high_usd, :low_usd, :close_usd, :source)

    # ---- Choisir la meilleure ligne par jour :
    # composite si dispo ce jour-là, sinon fallback sur une autre source.
    rows_by_day = rows.group_by { |(d, _o, _h, _l, _c, _src)| d }

    chosen_rows = rows_by_day.keys.sort.map do |day|
      day_rows = rows_by_day[day]

      # 1) composite prioritaire
      best = day_rows.find { |(_d, _o, _h, _l, _c, src)| src.to_s == "composite" }

      # 2) sinon première ligne non-nil (ordre DB déjà :day, mais sources mélangées)
      best ||= day_rows.find { |(_d, _o, _h, _l, c, _src)| c.present? }

      best
    end.compact

    @price_points = chosen_rows.map { |d, _o, _h, _l, c, _src| [d.strftime("%Y-%m-%d"), c.to_f] }

    # close series "YYYY-MM-DD" => close
    @series = chosen_rows.to_h { |d, _o, _h, _l, c, _src| [d.strftime("%Y-%m-%d"), c.to_f] }
    @price_series = @series

    # ---- True Exchange Flow (même période) ----
    flow_rows = ExchangeTrueFlow
      .where(day: from_day..to_day)
      .order(:day)
      .pluck(:day, :inflow_btc, :outflow_btc, :netflow_btc)

    flow_by_day = {}
    flow_rows.each do |d, inflow, outflow, net|
      k = d.strftime("%Y-%m-%d")
      flow_by_day[k] = { inflow: inflow&.to_d, outflow: outflow&.to_d, netflow: net&.to_d }
    end

    price_days = @price_points.map { |(day_str, _close)| day_str }
    @flows = price_days.map do |k|
      f = flow_by_day[k]
      {
        x: k,
        inflow:  f ? f[:inflow]&.to_f  : nil,
        outflow: f ? f[:outflow]&.to_f : nil,
        netflow: f ? f[:netflow]&.to_f : nil
      }
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

    # ---- Alignement prix/flows ----
    @alignment = PriceFlowAlignment.compute(days: days, price_series: @series)

    # ---- Alertes (strict-only via ton service actuel) ----
    @trader_alerts = TraderAlerts.for_market(
      price_metrics: {
        perf_pct: @perf_pct,
        pos_pct: @pos_pct,
        vol_pct: @vol_pct,
        max_drawdown_pct: @max_drawdown_pct
      },
      alignment: @alignment
    )

    # ---- Journal body ----
    alerts_txt =
      if @trader_alerts.present?
        @trader_alerts.map do |a|
          "- (#{a.level.to_s.upcase}) #{a.title}\n  #{a.message}\n  Action: #{a.hint}\n  Trigger: #{a.trigger}\n  Values: #{a.values.inspect}"
        end.join("\n")
      else
        "- Aucune alerte"
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

    # ---- Heuristique "ventes confirmées ?" (si tu veux la garder) ----
    flow_net = @alignment&.flow_net_btc.to_f
    flow_strong = 400.0

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

    # ---- Indicateur "Pression spéculative" (FIXE sur 30 jours) ----
    pressure_days = 30
    p_to   = Date.current - 1
    p_from = p_to - (pressure_days - 1)

    # Flows 30j
    p_flow = ExchangeTrueFlow
      .where(day: p_from..p_to)
      .order(:day)
      .pluck(:day, :inflow_btc, :outflow_btc, :netflow_btc)

    inflow_30  = p_flow.sum { |(_d, i, _o, _n)| i.to_d }.to_f
    outflow_30 = p_flow.sum { |(_d, _i, o, _n)| o.to_d }.to_f
    net_30     = p_flow.sum { |(_d, _i, _o, n)| n.to_d }.to_f

    # ratio30 (si la colonne existe) : on prend le dernier jour dispo
    ratio30_latest =
      begin
        ExchangeTrueFlow.where(day: p_from..p_to).order(day: :desc).limit(1).pick(:ratio30)&.to_f
      rescue StandardError
        nil
      end

    # Volatilité 30j (sur close)
    p_rows = BtcPriceDay
      .where(day: p_from..p_to)
      .where.not(close_usd: nil)
      .order(:day)
      .pluck(:day, :close_usd, :source)

    p_composite = p_rows.select { |(_d, _c, src)| src.to_s == "composite" }
    p_chosen    = p_composite.any? ? p_composite : p_rows
    p_values    = p_chosen.map { |(_d, c, _src)| c.to_f }

    vol_30 =
      if p_values.size >= 2
        rets = p_values.each_cons(2).map { |a, b| a.abs < 1e-12 ? 0.0 : ((b - a) / a * 100.0).abs }
        rets.empty? ? nil : (rets.sum / rets.size.to_f).round(2)
      else
        nil
      end

    # Whale events 30j (si modèle existant)
    whale_events_30 =
      begin
        WhaleAlert.where(occurred_at: p_from.beginning_of_day..p_to.end_of_day).count
      rescue StandardError
        0
      end

    @pressure_index = MarketPressureIndex.call(
      window_days: pressure_days,
      ratio30: ratio30_latest,
      vol_pct: vol_30,
      inflow_btc: inflow_30,
      outflow_btc: outflow_30,
      netflow_btc: net_30,
      whale_events: whale_events_30
    )

    #Rails.logger.warn("[pressure_index] label=#{@pressure_index&.label.inspect} ratio=#{@pressure_index&.facts&.dig(:ratio30).inspect} vol=#{@pressure_index&.facts&.dig(:vol_pct).inspect}")
    # ---- Indicateur "Maturité du marché" (30j glissants) ----
    maturity_days = 30
    m_to   = Date.current - 1
    m_from = m_to - (maturity_days - 1)

    # Volatilité 30j (réutilise la logique déjà utilisée pour pressure)
    m_rows = BtcPriceDay
      .where(day: m_from..m_to)
      .where.not(close_usd: nil)
      .order(:day)
      .pluck(:day, :close_usd, :source)

    m_composite = m_rows.select { |(_d, _c, src)| src.to_s == "composite" }
    m_chosen    = m_composite.any? ? m_composite : m_rows
    m_values    = m_chosen.map { |(_d, c, _src)| c.to_f }

    m_vol =
      if m_values.size >= 2
        rets = m_values.each_cons(2).map { |a, b| a.abs < 1e-12 ? 0.0 : ((b - a) / a * 100.0).abs }
        rets.empty? ? nil : (rets.sum / rets.size.to_f).round(2)
      else
        nil
      end

    # Whale events 30j (même source que pressure)
    m_whales =
      begin
        WhaleAlert.where(occurred_at: m_from.beginning_of_day..m_to.end_of_day).count
      rescue StandardError
        0
      end

    @maturity_index = MarketMaturityIndex.call(
      window_days: maturity_days,
      vol_pct: m_vol,
      whale_events: m_whales
    )
    
    # ---- Indicateur "Absorption / Distribution" (30j) ----
    @absorption_index = MarketAbsorptionIndex.call(
      window_days: 30,
      netflow_btc: net_30,
      perf_pct: @perf_pct
    )

    # ---- Synthèse macro (30j) ----
    @market_synthesis = MarketSynthesis.call(
      window_days: 30,
      pressure: @pressure_index,
      maturity: @maturity_index,
      absorption: @absorption_index
    )

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
