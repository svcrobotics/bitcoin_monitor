# app/services/true_exchange_inflow_rebuilder.rb

class TrueExchangeInflowRebuilder
  def self.call(days_back: 30)
    range = (days_back.days.ago.to_date)..Date.current

    range.each do |day|
      row = ExchangeFlow.find_or_initialize_by(day: day)

      inflow = ExchangeObservedUtxo
                 .where(seen_day: day)
                 .sum(:value_btc)
                 .to_d

      row.true_inflow_btc = inflow
      row.save!
    end
  end
end