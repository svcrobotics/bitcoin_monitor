# frozen_string_literal: true

class TradeSimulationCurveBuilder
  def self.call(sim)
    new(sim).call
  end

  def initialize(sim)
    @sim = sim
  end

  def call
    from = @sim.buy_day
    to   = BtcPriceDay.maximum(:day)
    return if from.blank? || to.blank? || from > to

    days = BtcPriceDay.where(day: from..to).order(:day).pluck(:day, :close_usd)

    days.each do |day, close_usd|
      temp = @sim.dup
      temp.sell_day = day

      r = TradeSimulator.call(temp)

      TradeSimulationPoint.upsert(
        {
          trade_simulation_id: @sim.id,
          day: day,
          price_usd: close_usd,
          net_usd: r.sell_net,
          pnl_usd: r.pnl,
          pnl_pct: r.pnl_pct,
          created_at: Time.current,
          updated_at: Time.current
        },
        unique_by: [:trade_simulation_id, :day]
      )
    end
  end
end
