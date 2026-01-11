# frozen_string_literal: true

module DecisionEngine
  class SellNow
    Result = Struct.new(
      :as_of_day,
      :buy_day,
      :btc_amount,
      :pnl_usd,
      :pnl_pct,
      :sell_net_usd,
      :buy_total_usd,
      :price_now_usd,
      keyword_init: true
    ) do
      # --- aliases rétro-compat (anciens noms) ---
      def net; sell_net_usd end
      def price; price_now_usd end

      def pnl; pnl_usd end          # ✅ fix "no member 'pnl'"
      def sell_net; sell_net_usd end
      def sell_price; price_now_usd end

      # Optionnel: noms hash-like si tu avais :net_usd, :price_usd etc.
      def net_usd; sell_net_usd end
      def price_usd; price_now_usd end
    end

    def self.call(sim, as_of_day: Date.current)
      new(sim, as_of_day: as_of_day).call
    end

    def initialize(sim, as_of_day:)
      @sim = sim
      @as_of_day = as_of_day
    end

    def call
      temp = @sim.dup
      temp.sell_day = @as_of_day

      r = TradeSimulator.call(temp)

      Result.new(
        as_of_day: @as_of_day,
        buy_day: @sim.buy_day,
        btc_amount: @sim.btc_amount,
        pnl_usd: r.pnl,
        pnl_pct: r.pnl_pct,
        sell_net_usd: r.sell_net,
        buy_total_usd: r.buy_total,
        price_now_usd: r.sell_price
      )
    end
  end
end
