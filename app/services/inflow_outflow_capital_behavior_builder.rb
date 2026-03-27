# frozen_string_literal: true

class InflowOutflowCapitalBehaviorBuilder
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
    flow     = ExchangeFlowDay.find_by(day: day)
    details  = ExchangeFlowDayDetail.find_by(day: day)
    behavior = ExchangeFlowDayBehavior.find_by(day: day)

    raise Error, "missing ExchangeFlowDay for #{day}" if flow.blank?
    raise Error, "missing ExchangeFlowDayDetail for #{day}" if details.blank?
    raise Error, "missing ExchangeFlowDayBehavior for #{day}" if behavior.blank?

    inflow_btc  = flow.inflow_btc.to_d
    outflow_btc = flow.outflow_btc.to_d
    total_flow  = inflow_btc + outflow_btc

    row = ExchangeFlowDayCapitalBehavior.find_or_initialize_by(day: day)

    # ------------------------------------------------------------
    # Capital ratios — deposits
    # retail       = <1 BTC + 1-10 BTC
    # whale        = 10-100 BTC + 100-500 BTC
    # institutional = >500 BTC
    # ------------------------------------------------------------
    retail_dep_btc = details.inflow_lt_1_btc.to_d + details.inflow_1_10_btc.to_d
    whale_dep_btc  = details.inflow_10_100_btc.to_d + details.inflow_100_500_btc.to_d
    inst_dep_btc   = details.inflow_gt_500_btc.to_d

    row.retail_deposit_capital_ratio        = safe_ratio(retail_dep_btc, inflow_btc)
    row.whale_deposit_capital_ratio         = safe_ratio(whale_dep_btc, inflow_btc)
    row.institutional_deposit_capital_ratio = safe_ratio(inst_dep_btc, inflow_btc)

    # ------------------------------------------------------------
    # Capital ratios — withdrawals
    # ------------------------------------------------------------
    retail_wd_btc = details.outflow_lt_1_btc.to_d + details.outflow_1_10_btc.to_d
    whale_wd_btc  = details.outflow_10_100_btc.to_d + details.outflow_100_500_btc.to_d
    inst_wd_btc   = details.outflow_gt_500_btc.to_d

    row.retail_withdrawal_capital_ratio        = safe_ratio(retail_wd_btc, outflow_btc)
    row.whale_withdrawal_capital_ratio         = safe_ratio(whale_wd_btc, outflow_btc)
    row.institutional_withdrawal_capital_ratio = safe_ratio(inst_wd_btc, outflow_btc)

    # ------------------------------------------------------------
    # Capital dominance
    # Simple V4 approach:
    # how much capital is dominated by whale + institutional volume
    # on both sides, then average the two
    # ------------------------------------------------------------
    deposit_cap_dom =
      row.whale_deposit_capital_ratio.to_d +
      row.institutional_deposit_capital_ratio.to_d

    withdrawal_cap_dom =
      row.whale_withdrawal_capital_ratio.to_d +
      row.institutional_withdrawal_capital_ratio.to_d

    row.capital_dominance_score = bound_0_1((deposit_cap_dom + withdrawal_cap_dom) / 2)

    # ------------------------------------------------------------
    # Whale distribution
    # Large capital going INTO exchanges
    # ------------------------------------------------------------
    inflow_dominance = safe_ratio(inflow_btc, total_flow)

    row.whale_distribution_score = bound_0_1(
      (row.whale_deposit_capital_ratio.to_d * 0.45) +
      (row.institutional_deposit_capital_ratio.to_d * 0.35) +
      (inflow_dominance.to_d * 0.20)
    )

    # ------------------------------------------------------------
    # Whale accumulation
    # Large capital going OUT OF exchanges
    # ------------------------------------------------------------
    outflow_dominance = safe_ratio(outflow_btc, total_flow)

    row.whale_accumulation_score = bound_0_1(
      (row.whale_withdrawal_capital_ratio.to_d * 0.45) +
      (row.institutional_withdrawal_capital_ratio.to_d * 0.35) +
      (outflow_dominance.to_d * 0.20)
    )

    # ------------------------------------------------------------
    # Count / Volume divergence
    # Compare V3 activity behavior vs V4 capital behavior
    # ------------------------------------------------------------
    dep_div =
      (behavior.whale_deposit_ratio.to_d - row.whale_deposit_capital_ratio.to_d).abs +
      (behavior.institutional_deposit_ratio.to_d - row.institutional_deposit_capital_ratio.to_d).abs

    wd_div =
      (behavior.whale_withdrawal_ratio.to_d - row.whale_withdrawal_capital_ratio.to_d).abs +
      (behavior.institutional_withdrawal_ratio.to_d - row.institutional_withdrawal_capital_ratio.to_d).abs

    row.count_volume_divergence_score = bound_0_1((dep_div + wd_div) / 2)

    # ------------------------------------------------------------
    # Capital behavior score
    # Synthetic score:
    # strong if capital dominated + strong distribution/accumulation
    # + strong divergence between count and volume
    # ------------------------------------------------------------
    directional_capital_score =
      (row.whale_distribution_score.to_d - row.whale_accumulation_score.to_d).abs

    row.capital_behavior_score = bound_0_1(
      (row.capital_dominance_score.to_d * 0.40) +
      (directional_capital_score.to_d * 0.30) +
      (row.count_volume_divergence_score.to_d * 0.30)
    )

    row.computed_at = Time.current
    row.save!

    puts "[inflow_outflow_capital_behavior_builder] day=#{day} " \
         "retail_dep_cap=#{fmt_ratio(row.retail_deposit_capital_ratio)} " \
         "whale_dep_cap=#{fmt_ratio(row.whale_deposit_capital_ratio)} " \
         "inst_dep_cap=#{fmt_ratio(row.institutional_deposit_capital_ratio)} " \
         "retail_wd_cap=#{fmt_ratio(row.retail_withdrawal_capital_ratio)} " \
         "whale_wd_cap=#{fmt_ratio(row.whale_withdrawal_capital_ratio)} " \
         "inst_wd_cap=#{fmt_ratio(row.institutional_withdrawal_capital_ratio)} " \
         "capital_dom=#{fmt_ratio(row.capital_dominance_score)} " \
         "whale_dist=#{fmt_ratio(row.whale_distribution_score)} " \
         "whale_acc=#{fmt_ratio(row.whale_accumulation_score)} " \
         "divergence=#{fmt_ratio(row.count_volume_divergence_score)} " \
         "capital_behavior=#{fmt_ratio(row.capital_behavior_score)}"

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