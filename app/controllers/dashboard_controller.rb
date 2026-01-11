# frozen_string_literal: true

class DashboardController < ApplicationController
  def index
    rpc = BitcoinRpc.new
    @snapshot = MarketSnapshot.order(computed_at: :desc).first

    # === Infos Bitcoin de base ===
    @blockchain = rpc.get_blockchain_info
    @mempool    = rpc.mempool_info

    minfee = @mempool["mempoolminfee"].to_f
    @min_sat_vb = (minfee * 100_000_000 / 1000).round
    @mempool_security = MempoolSecurityAnalyzer.new(@mempool, min_sat_vb: @min_sat_vb).call

    explorer       = BlockExplorer.new(rpc)
    @recent_blocks = explorer.recent_blocks(50)

    # === Résumé BRC-20 (juste pour le dashboard) ===
    coverage_from = 920_000
    coverage_to   = 926_028

    coverage_service = Brc20ScanCoverage.new(target_from: coverage_from, target_to: coverage_to)
    @brc20_scan_stats = coverage_service.stats
    @brc20_scan_done  = (@brc20_scan_stats[:missing_blocks].zero?)

    load_brc20_cron_status

    # === Lightning ===
    @lightning_status = LightningStatus.new.call

    @monitoring_rules = MonitoringRuleEngine.new(
      blockchain:       @blockchain,
      mempool:          @mempool,
      mempool_security: @mempool_security,
      lightning_status: @lightning_status,
      brc20_scan_stats: @brc20_scan_stats
    ).call

    # === Marché / prix ===
    @market_snapshot = MarketSnapshot.latest_ok
    @price_now       = BtcPriceDay.order(day: :desc).limit(1).pick(:close_usd)
    @price_zones     = PriceZone.for_dashboard(price_now: @price_now) if @price_now.present?
    @price_live      = CoingeckoClient.new.btc_price_usd

    # Flow (lecture + buy/sell decision)
    flow = ExchangeTrueFlow.recent.first

    # === Acheter aujourd'hui ? ===
    @buy_decision = if @market_snapshot.present? && @price_now.present?
      DecisionEngine::BuyNow.call(
        market_snapshot: @market_snapshot,
        price_now: @price_now,
        zones: @price_zones,
        flow: flow
      )
    end

    # === Lecture quotidienne ===
    @daily_reading = DailyReadingEngine.call(
      price_live: @price_live,
      price_close: @price_now,
      flow: flow,
      zones: @price_zones,
      market_snapshot: @market_snapshot
    )

    # === Position active + courbe ===
    @active_position = TradeSimulation.order(created_at: :desc).first
    @combo_series = []
    @pnl_info = nil
    points = nil

    if @active_position
      TradeSimulationCurveBuilder.call(@active_position)
      points = @active_position.points.order(:day)

      if points.present?
        @combo_series << {
          name: "Net (USD)",
          data: points.map { |p| [p.day.to_s, p.net_usd.to_f.round(2)] },
          yAxisID: "y"
        }

        last  = points.last
        best  = points.max_by  { |p| p.net_usd.to_f }
        worst = points.min_by  { |p| p.net_usd.to_f }

        @pnl_info = {
          last_day: last.day,
          last_net: last.net_usd,
          last_pnl_pct: last.pnl_pct,
          best_day: best.day,
          best_pnl_pct: best.pnl_pct,
          worst_day: worst.day,
          worst_pnl_pct: worst.pnl_pct
        }
      end
    end

    # === Si je vends aujourd'hui ===
    @sell_now = nil
    if @active_position
      begin
        @sell_now = DecisionEngine::SellNow.call(@active_position, as_of_day: Date.current)
      rescue TradeSimulator::PriceMissing
        last_day = BtcPriceDay.maximum(:day)
        @sell_now = DecisionEngine::SellNow.call(@active_position, as_of_day: last_day) if last_day
      end
    end

    # ✅ IMPORTANT : la vue _sell_now.html.erb attend @sell_score
    @sell_score = if @sell_now.present? && @market_snapshot.present?
      DecisionEngine::SellNowScore.call(
        market_snapshot: @market_snapshot,
        zones: @price_zones,
        flow: flow,
        sell_now: @sell_now,
        points: points # réutilise la variable déjà chargée
      )
    end

    # === IA (ne passe pas sell_now tant que la classe IA ne l'accepte pas) ===
    if @market_snapshot.present? && @price_now.present? && @price_zones.present?
      @ai_insight = Ai::ComputeDashboardInsight.new.call(
        market_snapshot: @market_snapshot,
        price_now: @price_now,
        price_zones: @price_zones
      )
    end

  rescue => e
    @error = e.message
    @blockchain          = nil
    @mempool             = nil
    @recent_blocks       = []
    @brc20_scan_stats    = nil
    @brc20_scan_done     = false
    @brc20_last_sync_run = nil
    @lightning_status    = { enabled: false, error: "Erreur Bitcoin RPC, Lightning non évalué" }
    @monitoring_rules    = []
  end

  private

  def load_brc20_cron_status
    file = Rails.root.join("tmp/brc20_last_run")
    @brc20_last_sync_run = File.exist?(file) ? (Time.parse(File.read(file)) rescue nil) : nil
  end
end
