# frozen_string_literal: true

module Btc
  class PeriodMetricsQuery
    class << self
      def call(history:)
        new(history: history).call
      end
    end

    def initialize(history:)
      @history = Array(history)
    end

    def call
      values = @history.map { |row| row[:close_usd].to_f }

      return empty_result if values.size < 2

      first = values.first
      last  = values.last
      high  = values.max
      low   = values.min

      perf_pct = first.abs < 1e-12 ? 0.0 : (((last - first) / first) * 100.0).round(2)

      range_val = high - low
      pos_pct = range_val.abs < 1e-12 ? 50 : (((last - low) / range_val) * 100).round

      peak = first
      max_dd = 0.0
      values.each do |v|
        peak = [peak, v].max
        next if peak <= 0

        dd = (v - peak) / peak.to_f * 100.0
        max_dd = [max_dd, dd].min
      end

      returns = values.each_cons(2).map do |a, b|
        next 0.0 if a.abs < 1e-12
        ((b - a) / a * 100.0).abs
      end

      vol_pct = returns.empty? ? 0.0 : (returns.sum / returns.size.to_f).round(2)
      vol_label = if vol_pct >= 4.0
        "Élevée"
      elsif vol_pct >= 2.0
        "Moyenne"
      else
        "Faible"
      end

      {
        perf_pct: perf_pct,
        high: high,
        low: low,
        pos_pct: pos_pct,
        max_drawdown_pct: max_dd.round(2),
        vol_pct: vol_pct,
        vol_label: vol_label
      }
    end

    private

    def empty_result
      {
        perf_pct: nil,
        high: nil,
        low: nil,
        pos_pct: nil,
        max_drawdown_pct: nil,
        vol_pct: nil,
        vol_label: nil
      }
    end
  end
end