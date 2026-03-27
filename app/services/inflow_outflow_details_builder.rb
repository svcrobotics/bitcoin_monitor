# frozen_string_literal: true

class InflowOutflowDetailsBuilder
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

    deposit_count   = inflow_scope.count
    inflow_total    = inflow_scope.sum(:value_btc).to_d
    avg_deposit     = deposit_count.positive? ? (inflow_total / deposit_count) : 0.to_d
    max_deposit     = inflow_scope.maximum(:value_btc).to_d

    withdrawal_count = outflow_scope.count
    outflow_total    = outflow_scope.sum(:value_btc).to_d
    avg_withdrawal   = withdrawal_count.positive? ? (outflow_total / withdrawal_count) : 0.to_d
    max_withdrawal   = outflow_scope.maximum(:value_btc).to_d

    row = ExchangeFlowDayDetail.find_or_initialize_by(day: day)

    # Inflow
    row.deposit_count    = deposit_count
    row.avg_deposit_btc  = avg_deposit
    row.max_deposit_btc  = max_deposit

    row.inflow_lt_1_btc     = bucket_sum(inflow_scope, 0, 1)
    row.inflow_1_10_btc     = bucket_sum(inflow_scope, 1, 10)
    row.inflow_10_100_btc   = bucket_sum(inflow_scope, 10, 100)
    row.inflow_100_500_btc  = bucket_sum(inflow_scope, 100, 500)
    row.inflow_gt_500_btc   = bucket_sum(inflow_scope, 500, nil)

    row.inflow_lt_1_count     = bucket_count(inflow_scope, 0, 1)
    row.inflow_1_10_count     = bucket_count(inflow_scope, 1, 10)
    row.inflow_10_100_count   = bucket_count(inflow_scope, 10, 100)
    row.inflow_100_500_count  = bucket_count(inflow_scope, 100, 500)
    row.inflow_gt_500_count   = bucket_count(inflow_scope, 500, nil)

    # Outflow
    row.withdrawal_count    = withdrawal_count
    row.avg_withdrawal_btc  = avg_withdrawal
    row.max_withdrawal_btc  = max_withdrawal

    row.outflow_lt_1_btc     = bucket_sum(outflow_scope, 0, 1)
    row.outflow_1_10_btc     = bucket_sum(outflow_scope, 1, 10)
    row.outflow_10_100_btc   = bucket_sum(outflow_scope, 10, 100)
    row.outflow_100_500_btc  = bucket_sum(outflow_scope, 100, 500)
    row.outflow_gt_500_btc   = bucket_sum(outflow_scope, 500, nil)

    row.outflow_lt_1_count     = bucket_count(outflow_scope, 0, 1)
    row.outflow_1_10_count     = bucket_count(outflow_scope, 1, 10)
    row.outflow_10_100_count   = bucket_count(outflow_scope, 10, 100)
    row.outflow_100_500_count  = bucket_count(outflow_scope, 100, 500)
    row.outflow_gt_500_count   = bucket_count(outflow_scope, 500, nil)

    row.computed_at = Time.current
    row.save!

    puts "[inflow_outflow_details_builder] day=#{day} " \
         "deposit_count=#{deposit_count} avg_deposit_btc=#{format_btc(avg_deposit)} max_deposit_btc=#{format_btc(max_deposit)} " \
         "withdrawal_count=#{withdrawal_count} avg_withdrawal_btc=#{format_btc(avg_withdrawal)} max_withdrawal_btc=#{format_btc(max_withdrawal)}"
  end

  def bucket_sum(scope, min, max)
    apply_bucket(scope, min, max).sum(:value_btc).to_d
  end

  def bucket_count(scope, min, max)
    apply_bucket(scope, min, max).count
  end

  def apply_bucket(scope, min, max)
    if max.nil?
      scope.where("value_btc >= ?", min)
    elsif min.zero?
      scope.where("value_btc < ?", max)
    else
      scope.where("value_btc >= ? AND value_btc < ?", min, max)
    end
  end

  def format_btc(value)
    value.to_d.to_s("F")
  end
end