# app/services/market_data/compute_price_zones.rb
module MarketData
  class ComputePriceZones
    TIMEFRAME = "1y_daily"

    def initialize(window: 3, lookback_days: 365, tolerance_pct: 0.012, logger: Rails.logger)
      @window = window
      @lookback_days = lookback_days
      @tolerance_pct = tolerance_pct
      @logger = logger
    end

    def call
      pivots = MarketData::PivotDetector.new(window: @window, lookback_days: @lookback_days).call
      clusterer = MarketData::ZoneClusterer.new(tolerance_pct: @tolerance_pct)

      support_clusters = clusterer.call(pivots: pivots[:lows], kind: "support")
      resist_clusters  = clusterer.call(pivots: pivots[:highs], kind: "resistance")

      zones = []
      zones += clusters_to_zones(support_clusters, "support")
      zones += clusters_to_zones(resist_clusters, "resistance")

      # Filtre strength >= 45
      zones.select! { |z| z[:strength] >= 45 }

      persist!(zones)

      @logger.info("[MarketData::ComputePriceZones] zones=#{zones.size} (support=#{zones.count { _1[:kind] == 'support' }}, resistance=#{zones.count { _1[:kind] == 'resistance' }})")
      zones
    end

    private

    def clusters_to_zones(clusters, kind)
      clusters.map do |c|
        touches = c.touches.size
        last_touch_day = c.touches.map(&:day).max

        strength = compute_strength(touches: touches, last_touch_day: last_touch_day)

        {
          kind: kind,
          low_usd: c.low,
          high_usd: c.high,
          strength: strength,
          touches_count: touches,
          timeframe: TIMEFRAME,
          computed_at: Time.current,
          note: "Cluster ±#{(@tolerance_pct * 100).round(1)}% (N=#{@window}, lookback=#{@lookback_days}j)"
        }
      end
    end

    def compute_strength(touches:, last_touch_day:)
      touches_score = [touches * 12, 60].min

      days_ago = (Date.today - last_touch_day).to_i
      recency_score =
        if days_ago <= 30
          40
        elsif days_ago <= 90
          25
        elsif days_ago <= 180
          10
        else
          0
        end

      total = touches_score + recency_score
      [[total, 0].max, 100].min
    end

    def persist!(zones)
      # On remplace le dernier set de zones : simple et efficace pour MVP
      PriceZone.where(timeframe: TIMEFRAME).delete_all

      now = Time.current
      rows = zones.map do |z|
        z.merge(created_at: now, updated_at: now)
      end

      PriceZone.insert_all(rows) if rows.any?
    end
  end
end
