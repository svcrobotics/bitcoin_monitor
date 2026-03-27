# frozen_string_literal: true

class ExchangeTrueFlowBaselineRebuilder
  WINDOWS = [7, 30, 200].freeze

  def self.call(days_back: 220)
    new(days_back: days_back).call
  end

  def initialize(days_back:)
    @days_back = days_back
  end

  def call
    scope = ExchangeTrueFlow
      .where(day: (@days_back.days.ago.to_date)..Date.current)
      .order(:day)

    flows = scope.to_a

    flows.each_with_index do |f, idx|
      # Baselines uniquement si on a une mesure "valide"
      # (covered=true et inflow_btc non nil)
      f.avg7   = avg_over(flows, idx, 7)
      f.avg30  = avg_over(flows, idx, 30)
      f.avg200 = avg_over(flows, idx, 200)

      f.ratio30 = ratio(f.inflow_btc, f.avg30)

      f.save! if f.changed?
    end
  end

  private

  def avg_over(flows, idx, window)
    to = idx - 1
    return nil if to < 0

    from  = [0, to - (window - 1)].max
    slice = flows[from..to]
    return nil if slice.blank?

    # on ignore les jours non couverts / nil
    slice = slice.select { |x| x.covered? && x.inflow_btc.present? }
    return nil if slice.empty?

    sum = slice.sum { |x| x.inflow_btc.to_d }
    (sum / slice.size).to_d
  end

  def ratio(value, baseline)
    return nil if value.nil?
    return nil if baseline.blank? || baseline.to_d <= 0
    (value.to_d / baseline.to_d).round(4)
  end
end