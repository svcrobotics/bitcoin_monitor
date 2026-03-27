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
    return if from.blank?

    last_price_day = BtcPriceDay.maximum(:day)
    return if last_price_day.blank?

    logical_to =
      if @sim.respond_to?(:closed?) && @sim.closed?
        @sim.sell_day
      else
        Date.current
      end
    return if logical_to.blank?

    to = [logical_to, last_price_day].min
    return if from > to

    # ✅ EUR (au lieu de close_usd)
    days = BtcPriceDay.where(day: from..to).order(:day).pluck(:day, :close_eur)

    days.each do |day, close_eur|
      next if close_eur.nil? # si pas encore backfill

      temp = @sim.dup
      temp.sell_day = day

      r = TradeSimulator.call(temp) # ton TradeSimulator doit utiliser close_eur_for!

      TradeSimulationPoint.upsert(
        {
          trade_simulation_id: @sim.id,
          day: day,

          # ⚠️ colonnes nommées *_usd, mais contiennent des EUR
          price_usd: close_eur,
          net_usd: r.sell_net,
          pnl_usd: r.pnl,
          pnl_pct: r.pnl_pct,

          created_at: Time.current,
          updated_at: Time.current
        },
        unique_by: %i[trade_simulation_id day]
      )
    rescue TradeSimulator::PriceMissing
      next
    end
  end
end
