# app/services/market_data/pivot_detector.rb
module MarketData
  class PivotDetector
    Pivot = Struct.new(:day, :price, keyword_init: true)

    def initialize(window: 3, lookback_days: 365)
      @window = window
      @lookback_days = lookback_days
    end

    # Retourne: { lows: [Pivot...], highs: [Pivot...] }
    def call
      rows = load_rows
      return { lows: [], highs: [] } if rows.size < (@window * 2 + 1)

      lows  = []
      highs = []

      closes = rows.map { |r| r[:close] }
      days   = rows.map { |r| r[:day] }

      # On évite les bords (il faut window jours avant/après)
      (@window...(rows.size - @window)).each do |i|
        c = closes[i]

        left  = closes[(i - @window)...i]
        right = closes[(i + 1)..(i + @window)]

        if left.all? { |x| c < x } && right.all? { |x| c < x }
          lows << Pivot.new(day: days[i], price: c)
        end

        if left.all? { |x| c > x } && right.all? { |x| c > x }
          highs << Pivot.new(day: days[i], price: c)
        end
      end

      { lows: lows, highs: highs }
    end

    private

    def load_rows
      from_day = Date.today - @lookback_days

      BtcPriceDay
        .where("day >= ?", from_day)
        .order(day: :asc)
        .pluck(:day, :close_usd)
        .map { |day, close| { day: day, close: close.to_d } }
    end
  end
end
