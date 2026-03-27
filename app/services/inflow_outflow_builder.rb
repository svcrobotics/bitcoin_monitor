# frozen_string_literal: true

class InflowOutflowBuilder
  class Error < StandardError; end

  def self.call(day: nil, days_back: nil)
    new(day: day, days_back: days_back).call
  end

  def initialize(day:, days_back:)
    @day = day.present? ? Date.parse(day.to_s) : nil
    @days_back = days_back.present? ? days_back.to_i : nil
  end

  def call
    if @day.present?
      build_day!(@day)
      return { ok: true, mode: :single_day, day: @day }
    end

    if @days_back.present? && @days_back > 0
      days = ((Date.current - (@days_back - 1))..Date.current).to_a
      days.each { |d| build_day!(d) }
      return { ok: true, mode: :days_back, from: days.first, to: days.last, count: days.size }
    end

    days = [Date.yesterday, Date.current].uniq
    days.each { |d| build_day!(d) }

    { ok: true, mode: :default, days: days }
  end

  private

  def build_day!(day)
    inflow_scope  = ExchangeObservedUtxo.where(seen_day: day)
    outflow_scope = ExchangeObservedUtxo.where(spent_day: day)

    inflow_btc        = inflow_scope.sum(:value_btc)
    outflow_btc       = outflow_scope.sum(:value_btc)
    inflow_utxo_count = inflow_scope.count
    outflow_utxo_count = outflow_scope.count

    row = ExchangeFlowDay.find_or_initialize_by(day: day)

    row.inflow_btc         = inflow_btc
    row.outflow_btc        = outflow_btc
    row.netflow_btc        = inflow_btc - outflow_btc
    row.inflow_utxo_count  = inflow_utxo_count
    row.outflow_utxo_count = outflow_utxo_count
    row.computed_at        = Time.current

    row.save!

    puts "[inflow_outflow_builder] day=#{day} " \
         "inflow_btc=#{format_btc(inflow_btc)} " \
         "outflow_btc=#{format_btc(outflow_btc)} " \
         "netflow_btc=#{format_btc(row.netflow_btc)} " \
         "inflow_utxo_count=#{inflow_utxo_count} " \
         "outflow_utxo_count=#{outflow_utxo_count}"
  end

  def format_btc(value)
    value.to_d.to_s("F")
  end
end