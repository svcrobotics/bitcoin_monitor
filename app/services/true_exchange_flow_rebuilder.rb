# frozen_string_literal: true

class TrueExchangeFlowRebuilder
  def self.call(days_back: 30, only_missing: false)
    new(days_back: days_back, only_missing: only_missing).call
  end

  def initialize(days_back:, only_missing:)
    @days_back    = days_back.to_i
    @only_missing = !!only_missing
  end

  def call
    range = (@days_back.days.ago.to_date)..Date.current

    range.each do |day|
      row = ExchangeFlow.find_or_initialize_by(day: day)

      if @only_missing
        next unless row.true_inflow_btc.nil? || row.true_outflow_btc.nil?
      end

      inflow = ExchangeObservedUtxo
                 .where(seen_day: day)
                 .sum(:value_btc)
                 .to_d

      outflow = ExchangeObservedUtxo
                  .where(spent_day: day)
                  .sum(:value_btc)
                  .to_d

      row.true_inflow_btc  = inflow
      row.true_outflow_btc = outflow
      row.true_net_btc     = inflow - outflow

      row.save! if row.changed?
    end

    true
  end
end