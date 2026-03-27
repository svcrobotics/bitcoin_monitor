# frozen_string_literal: true

class InflowOutflowBehaviorBuilder
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
    flow    = ExchangeFlowDay.find_by(day: day)
    details = ExchangeFlowDayDetail.find_by(day: day)

    raise Error, "missing ExchangeFlowDay for #{day}" if flow.blank?
    raise Error, "missing ExchangeFlowDayDetail for #{day}" if details.blank?

    deposit_count    = details.deposit_count.to_i
    withdrawal_count = details.withdrawal_count.to_i

    inflow_btc  = flow.inflow_btc.to_d
    outflow_btc = flow.outflow_btc.to_d

    row = ExchangeFlowDayBehavior.find_or_initialize_by(day: day)

    # ------------------------------------------------------------
    # Deposit ratios (count)
    # retail      = <1 BTC + 1-10 BTC
    # whale       = 10-100 BTC + 100-500 BTC
    # institutional = >500 BTC
    # ------------------------------------------------------------
    retail_deposit_count = details.inflow_lt_1_count.to_i + details.inflow_1_10_count.to_i
    whale_deposit_count  = details.inflow_10_100_count.to_i + details.inflow_100_500_count.to_i
    inst_deposit_count   = details.inflow_gt_500_count.to_i

    row.retail_deposit_ratio        = safe_ratio(retail_deposit_count, deposit_count)
    row.whale_deposit_ratio         = safe_ratio(whale_deposit_count, deposit_count)
    row.institutional_deposit_ratio = safe_ratio(inst_deposit_count, deposit_count)

    # ------------------------------------------------------------
    # Deposit ratios (volume)
    # ------------------------------------------------------------
    retail_deposit_btc = details.inflow_lt_1_btc.to_d + details.inflow_1_10_btc.to_d
    whale_deposit_btc  = details.inflow_10_100_btc.to_d + details.inflow_100_500_btc.to_d
    inst_deposit_btc   = details.inflow_gt_500_btc.to_d

    row.retail_deposit_volume_ratio        = safe_ratio(retail_deposit_btc, inflow_btc)
    row.whale_deposit_volume_ratio         = safe_ratio(whale_deposit_btc, inflow_btc)
    row.institutional_deposit_volume_ratio = safe_ratio(inst_deposit_btc, inflow_btc)

    # ------------------------------------------------------------
    # Withdrawal ratios (count)
    # ------------------------------------------------------------
    retail_withdrawal_count = details.outflow_lt_1_count.to_i + details.outflow_1_10_count.to_i
    whale_withdrawal_count  = details.outflow_10_100_count.to_i + details.outflow_100_500_count.to_i
    inst_withdrawal_count   = details.outflow_gt_500_count.to_i

    row.retail_withdrawal_ratio        = safe_ratio(retail_withdrawal_count, withdrawal_count)
    row.whale_withdrawal_ratio         = safe_ratio(whale_withdrawal_count, withdrawal_count)
    row.institutional_withdrawal_ratio = safe_ratio(inst_withdrawal_count, withdrawal_count)

    # ------------------------------------------------------------
    # Withdrawal ratios (volume)
    # ------------------------------------------------------------
    retail_withdrawal_btc = details.outflow_lt_1_btc.to_d + details.outflow_1_10_btc.to_d
    whale_withdrawal_btc  = details.outflow_10_100_btc.to_d + details.outflow_100_500_btc.to_d
    inst_withdrawal_btc   = details.outflow_gt_500_btc.to_d

    row.retail_withdrawal_volume_ratio        = safe_ratio(retail_withdrawal_btc, outflow_btc)
    row.whale_withdrawal_volume_ratio         = safe_ratio(whale_withdrawal_btc, outflow_btc)
    row.institutional_withdrawal_volume_ratio = safe_ratio(inst_withdrawal_btc, outflow_btc)

    # ------------------------------------------------------------
    # Concentration scores
    # Simple V3 approach:
    # concentration = whale volume ratio + institutional volume ratio
    # bounded to 1.0
    # ------------------------------------------------------------
    row.deposit_concentration_score = bound_0_1(
      row.whale_deposit_volume_ratio.to_d + row.institutional_deposit_volume_ratio.to_d
    )

    row.withdrawal_concentration_score = bound_0_1(
      row.whale_withdrawal_volume_ratio.to_d + row.institutional_withdrawal_volume_ratio.to_d
    )

    # ------------------------------------------------------------
    # Distribution / Accumulation
    # Simple V3 heuristic:
    #
    # distribution:
    #   50% deposit concentration
    #   30% institutional deposit volume ratio
    #   20% inflow dominance over total flow
    #
    # accumulation:
    #   50% withdrawal concentration
    #   30% institutional withdrawal volume ratio
    #   20% outflow dominance over total flow
    # ------------------------------------------------------------
    total_flow = inflow_btc + outflow_btc

    inflow_dominance  = safe_ratio(inflow_btc, total_flow)
    outflow_dominance = safe_ratio(outflow_btc, total_flow)

    row.distribution_score = bound_0_1(
      (row.deposit_concentration_score.to_d * 0.5) +
      (row.institutional_deposit_volume_ratio.to_d * 0.3) +
      (inflow_dominance.to_d * 0.2)
    )

    row.accumulation_score = bound_0_1(
      (row.withdrawal_concentration_score.to_d * 0.5) +
      (row.institutional_withdrawal_volume_ratio.to_d * 0.3) +
      (outflow_dominance.to_d * 0.2)
    )

    # ------------------------------------------------------------
    # Behavior score
    # Absolute difference between accumulation and distribution,
    # shifted toward dominant side.
    #
    # 0   => neutral / balanced
    # 1.0 => strongly one-sided behavior
    # ------------------------------------------------------------
    row.behavior_score = (row.accumulation_score.to_d - row.distribution_score.to_d).abs

    row.computed_at = Time.current
    row.save!

    puts "[inflow_outflow_behavior_builder] day=#{day} " \
         "retail_dep=#{fmt_ratio(row.retail_deposit_ratio)} " \
         "whale_dep=#{fmt_ratio(row.whale_deposit_ratio)} " \
         "inst_dep=#{fmt_ratio(row.institutional_deposit_ratio)} " \
         "retail_wd=#{fmt_ratio(row.retail_withdrawal_ratio)} " \
         "whale_wd=#{fmt_ratio(row.whale_withdrawal_ratio)} " \
         "inst_wd=#{fmt_ratio(row.institutional_withdrawal_ratio)} " \
         "dist=#{fmt_ratio(row.distribution_score)} " \
         "acc=#{fmt_ratio(row.accumulation_score)} " \
         "behavior=#{fmt_ratio(row.behavior_score)}"

    row
  end

  def safe_ratio(num, den)
    den_bd = den.to_d
    return 0.to_d if den_bd <= 0

    num.to_d / den_bd
  end

  def bound_0_1(value)
    v = value.to_d
    return 0.to_d if v < 0
    return 1.to_d if v > 1

    v
  end

  def fmt_ratio(value)
    value.to_d.round(6).to_s("F")
  end
end