# frozen_string_literal: true

class DashboardController < ApplicationController
  def index
    init_defaults

    rpc = BitcoinRpc.new

    load_bitcoin_core!(rpc)
    load_recent_blocks!(rpc)
    load_brc20_status!
    load_lightning_status!
    load_monitoring_rules!

    load_market_data!
    load_hero_metrics! # <-- NOUVEAU : alimente market/_dashboard_summary

    flow = load_flow!
    load_buy_decision!(flow)
    load_daily_reading!(flow)

    points = load_active_position_and_curve!
    load_sell_now!
    load_sell_score!(flow, points)

    load_ai_insight!
  rescue => e
    handle_dashboard_error!(e)
  end

  private

  # -------------------------
  # Defaults / Error handling
  # -------------------------

  def init_defaults
    @error = nil

    @blockchain = nil
    @mempool = nil
    @mempool_security = nil
    @min_sat_vb = nil
    @recent_blocks = []

    @brc20_scan_stats = nil
    @brc20_scan_done = false
    @brc20_last_sync_run = nil

    @lightning_status = { enabled: false }
    @monitoring_rules = []

    # Marché / HERO
    @snapshot = nil
    @range = params[:range].presence || "30d"
    @alerts_mode = params[:alerts_mode].presence || "strict"

    @one_liner = nil
    @perf_pct = nil
    @high = nil
    @low = nil
    @pos_pct = nil
    @max_drawdown_pct = nil
    @vol_label = nil
    @vol_pct = nil

    @ma200 = nil
    @ma_badge = nil
    @px_vs_ma200_pct = nil
    @px_now = nil

    @alignment = nil
    @sell_verdict = nil
    @trader_alerts = []

    # Market / Price / Zones
    @price_now = nil
    @price_live = nil
    @price_zones = nil

    # Decisions
    @buy_decision = nil
    @daily_reading = nil

    # Position
    @active_position = nil
    @combo_series = []
    @pnl_info = nil
    @sell_now = nil
    @sell_score = nil

    # IA
    @ai_insight = nil
  end

  def handle_dashboard_error!(e)
    @error = e.message
    Rails.logger.error("[DASHBOARD] #{e.class}: #{e.message}\n#{e.backtrace&.first(20)&.join("\n")}")

    # On garde les valeurs par défaut déjà mises par init_defaults
    @lightning_status = { enabled: false, error: "Erreur dashboard, Lightning non évalué" }
    @monitoring_rules = []
  end

  # -------------------------
  # Bitcoin Core / Blocks
  # -------------------------

  def load_bitcoin_core!(rpc)
    @blockchain = rpc.get_blockchain_info
    @mempool    = rpc.mempool_info

    minfee = @mempool["mempoolminfee"].to_f
    @min_sat_vb = (minfee * 100_000_000 / 1000).round

    @mempool_security = MempoolSecurityAnalyzer.new(@mempool, min_sat_vb: @min_sat_vb).call
  end

  def load_recent_blocks!(rpc)
    explorer = BlockExplorer.new(rpc)
    @recent_blocks = explorer.recent_blocks(50)
  end

  # -------------------------
  # BRC-20 + cron marker
  # -------------------------

  def load_brc20_status!
    coverage_from = 920_000
    coverage_to   = 926_028

    coverage_service = Brc20ScanCoverage.new(target_from: coverage_from, target_to: coverage_to)
    @brc20_scan_stats = coverage_service.stats
    @brc20_scan_done  = (@brc20_scan_stats[:missing_blocks].zero?)

    load_brc20_cron_status
  end

  def load_brc20_cron_status
    file = Rails.root.join("tmp/brc20_last_run")
    @brc20_last_sync_run = File.exist?(file) ? (Time.parse(File.read(file)) rescue nil) : nil
  end

  # -------------------------
  # Lightning + monitoring
  # -------------------------

  def load_lightning_status!
    @lightning_status = LightningStatus.new.call
  end

  def load_monitoring_rules!
    @monitoring_rules = MonitoringRuleEngine.new(
      blockchain:       @blockchain,
      mempool:          @mempool,
      mempool_security: @mempool_security,
      lightning_status: @lightning_status,
      brc20_scan_stats: @brc20_scan_stats
    ).call
  end

  # -------------------------
  # Market / Price / Zones
  # -------------------------

  def load_market_data!
    # On garde @snapshot car ta vue l’utilise
    @snapshot    = MarketSnapshot.order(computed_at: :desc).first
    @price_now   = BtcPriceDay.order(day: :desc).limit(1).pick(:close_usd)
    @price_zones = PriceZone.for_dashboard(price_now: @price_now) if @price_now.present?
    @price_live  = CoingeckoClient.new.btc_price_usd
  end

  # -------------------------
  # HERO metrics (pour market/_dashboard_summary)
  # -------------------------

  def load_hero_metrics!
    return unless @snapshot.present?

    # Prix "now" affiché dans le bloc MA200
    @px_now = @price_now

    # MA200 + distance
    @ma200 = @snapshot.ma200_usd
    @px_vs_ma200_pct = @snapshot.price_vs_ma200_pct

    @ma_badge =
      if @px_vs_ma200_pct.to_f >= 0
        "above"
      else
        "below"
      end

    # Alignment / verdict (simple) : on met une base cohérente même sans moteur dédié
    @alignment = @snapshot.market_bias.presence || "neutral"

    # On essaye une décision simple : si price sous MA200 => attendre
    @sell_verdict =
      if @px_vs_ma200_pct.to_f < 0
        "attendre"
      else
        "attendre"
      end

    # One-liner : on réutilise les reasons du snapshot si présentes
    @one_liner = Array(@snapshot.reasons).first.to_s.presence

    # Plage pour les métriques (7d / 30d / 1y)
    days =
      case @range.to_s
      when "7d"  then 7
      when "30d" then 30
      when "1y"  then 365
      else 30
      end

    load_period_metrics!(days)
    load_volatility!(days)

    # Alerts trader : si tu as déjà un moteur, branche-le ici.
    # Sinon on laisse vide (ta vue gère déjà).
    @trader_alerts ||= []
  end

  def load_period_metrics!(days)
    return unless @price_now.present?

    last_day = BtcPriceDay.maximum(:day)
    return unless last_day

    start_day = last_day - (days - 1)

    rows = BtcPriceDay.where(day: start_day..last_day).order(:day).pluck(:day, :close_usd)
    return if rows.size < 2

    closes = rows.map { |(_, c)| c.to_f }
    first  = closes.first
    last   = closes.last

    @high = closes.max
    @low  = closes.min

    @perf_pct = first.zero? ? nil : ((last - first) / first * 100.0)
    range = (@high - @low)
    @pos_pct = range.zero? ? nil : ((last - @low) / range * 100.0)

    # Max drawdown approx sur la période : peak-to-trough
    peak = closes.first
    max_dd = 0.0
    closes.each do |c|
      peak = [peak, c].max
      dd = peak.zero? ? 0.0 : ((peak - c) / peak * 100.0)
      max_dd = [max_dd, dd].max
    end
    @max_drawdown_pct = max_dd
  end

  def load_volatility!(days)
    last_day = BtcPriceDay.maximum(:day)
    return unless last_day

    start_day = last_day - (days - 1)
    rows = BtcPriceDay.where(day: start_day..last_day).order(:day).pluck(:close_usd)
    return if rows.size < 3

    # Volatilité simple: écart-type des rendements journaliers (en %)
    returns = []
    rows.each_cons(2) do |a, b|
      a = a.to_f
      b = b.to_f
      next if a.zero?
      returns << ((b - a) / a * 100.0)
    end
    return if returns.empty?

    mean = returns.sum / returns.size
    var = returns.map { |r| (r - mean) ** 2 }.sum / returns.size
    sd = Math.sqrt(var)

    @vol_pct = sd
    @vol_label =
      if sd < 1.5
        "Faible"
      elsif sd < 3.0
        "Moyenne"
      else
        "Élevée"
      end
  end

  # -------------------------
  # Flow / Decisions / Reading
  # -------------------------

  def load_flow!
    ExchangeTrueFlow.recent.first
  end

  def load_buy_decision!(flow)
    return unless @snapshot.present? && @price_now.present?

    @buy_decision = DecisionEngine::BuyNow.call(
      market_snapshot: @snapshot,
      price_now: @price_now,
      zones: @price_zones,
      flow: flow
    )

    # Si ton BuyNow renvoie une action, tu peux influencer sell_verdict ici
    # (optionnel) :
    # @sell_verdict = @buy_decision[:action].to_s.downcase if @buy_decision.is_a?(Hash)
  end

  def load_daily_reading!(flow)
    @daily_reading = DailyReadingEngine.call(
      price_live: @price_live,
      price_close: @price_now,
      flow: flow,
      zones: @price_zones,
      market_snapshot: @snapshot
    )

    # Si ton daily_reading contient une phrase ou verdict, tu peux le brancher :
    # @one_liner ||= @daily_reading["one_liner"] if @daily_reading.is_a?(Hash)
  end

  # -------------------------
  # Position / Curve
  # -------------------------

  def load_active_position_and_curve!
    @active_position = TradeSimulation.order(created_at: :desc).first
    return nil unless @active_position

    TradeSimulationCurveBuilder.call(@active_position)
    points = @active_position.points.order(:day)
    return nil unless points.present?

    @combo_series << {
      name: "Net (USD)",
      data: points.map { |p| [p.day.to_s, p.net_usd.to_f.round(2)] },
      yAxisID: "y"
    }

    last  = points.last
    best  = points.max_by { |p| p.net_usd.to_f }
    worst = points.min_by { |p| p.net_usd.to_f }

    @pnl_info = {
      last_day: last.day,
      last_net: last.net_usd,
      last_pnl_pct: last.pnl_pct,
      best_day: best.day,
      best_pnl_pct: best.pnl_pct,
      worst_day: worst.day,
      worst_pnl_pct: worst.pnl_pct
    }

    points
  end

  # -------------------------
  # Sell now / Score
  # -------------------------

  def load_sell_now!
    return unless @active_position

    @sell_now = DecisionEngine::SellNow.call(@active_position, as_of_day: Date.current)
  rescue TradeSimulator::PriceMissing
    last_day = BtcPriceDay.maximum(:day)
    @sell_now = DecisionEngine::SellNow.call(@active_position, as_of_day: last_day) if last_day
  end

  def load_sell_score!(flow, points)
    return unless @sell_now.present? && @snapshot.present?

    @sell_score = DecisionEngine::SellNowScore.call(
      market_snapshot: @snapshot,
      zones: @price_zones,
      flow: flow,
      sell_now: @sell_now,
      points: points
    )
  end

  # -------------------------
  # AI Insight (NEUTRAL / DAILY)
  # -------------------------

  def load_ai_insight!
    return unless ENV["OPENAI_API_KEY"].present?
    return unless @snapshot.present? && @price_now.present? && @price_zones.present?

    begin
      as_of_day = BtcPriceDay.maximum(:day) || Date.current

      # Série 7j + 30j (OHLC compact). Si tu n'as pas open/high/low en DB,
      # laisse open/high/low à nil ou mappe uniquement close -> ohlc minimal.
      series_7d = BtcPriceDay.where(day: (as_of_day - 6)..as_of_day).order(:day).pluck(:day, :open_usd, :high_usd, :low_usd, :close_usd).map do |day, o, h, l, c|
        { day: day, open: o, high: h, low: l, close: c }
      end

      series_30d = BtcPriceDay.where(day: (as_of_day - 29)..as_of_day).order(:day).pluck(:day, :open_usd, :high_usd, :low_usd, :close_usd).map do |day, o, h, l, c|
        { day: day, open: o, high: h, low: l, close: c }
      end

      # Si ta table BtcPriceDay n’a PAS open/high/low (cas probable),
      # remplace les 2 blocks ci-dessus par une version close-only :
      #
      # series_7d = BtcPriceDay.where(day: (as_of_day - 6)..as_of_day).order(:day).pluck(:day, :close_usd).map { |d, c| { day: d, close: c } }
      # series_30d = BtcPriceDay.where(day: (as_of_day - 29)..as_of_day).order(:day).pluck(:day, :close_usd).map { |d, c| { day: d, close: c } }

      price_for_ai = (@price_now.to_f / 10.0).round * 10.0

      @ai_insight = Ai::ComputeDashboardInsight.new.call(
        as_of_day: as_of_day,
        market_snapshot: @snapshot,
        price_now: price_for_ai,
        price_zones: @price_zones,
        series_7d: series_7d,
        series_30d: series_30d
      )
    rescue => e
      Rails.logger.warn("[AI] dashboard insight failed: #{e.class}: #{e.message}")
      @ai_insight = nil
    end
  end

end
