class InflowOutflowController < ApplicationController
  def index
    rows = ExchangeFlowDay.order(day: :asc)

    @recent_days =
      ExchangeFlowDay
        .order(day: :desc)
        .limit(7)

    @latest_day = ExchangeFlowDay.maximum(:day)

    @latest_day_in_progress =
      @latest_day.present? && @latest_day == Date.current

    latest_row =
      ExchangeFlowDay
        .order(day: :desc)
        .first

    @summary =
      if latest_row
        {
          day: latest_row.day,
          inflow_btc: latest_row.inflow_btc,
          outflow_btc: latest_row.outflow_btc,
          netflow_btc: latest_row.netflow_btc
        }
      else
        {
          day: nil,
          inflow_btc: 0,
          outflow_btc: 0,
          netflow_btc: 0
        }
      end

    flow_rows =
      ExchangeFlowDay
        .where("day >= ?", 30.days.ago.to_date)
        .order(:day)

    @inflow_daily =
      fill_daily_series(
        flow_rows.index_by(&:day).transform_values { |r| r.inflow_btc.to_d.round },
        days: 30
      )

    @outflow_daily =
      fill_daily_series(
        flow_rows.index_by(&:day).transform_values { |r| r.outflow_btc.to_d.round },
        days: 30
      )

    @netflow_daily =
      fill_daily_series(
        flow_rows.index_by(&:day).transform_values { |r| r.netflow_btc.to_d.round },
        days: 30
      )

    @days_total = ExchangeFlowDay.count

    last_job =
      JobRun
        .where(name: "inflow_outflow_build")
        .order(started_at: :desc)
        .first

    @engine_status = {
      last_computed_day: @latest_day,
      last_job_status: last_job&.status,
      last_job_duration_ms: last_job&.duration_ms
    }

    # =========================
    # V2 details
    # =========================
    @details_latest =
      if @latest_day.present?
        ExchangeFlowDayDetail.find_by(day: @latest_day)
      end

    if @details_latest.present?
      @deposit_summary = {
        deposit_count: @details_latest.deposit_count,
        avg_deposit_btc: @details_latest.avg_deposit_btc.to_d,
        max_deposit_btc: @details_latest.max_deposit_btc.to_d
      }

      @withdrawal_summary = {
        withdrawal_count: @details_latest.withdrawal_count,
        avg_withdrawal_btc: @details_latest.avg_withdrawal_btc.to_d,
        max_withdrawal_btc: @details_latest.max_withdrawal_btc.to_d
      }

      @deposit_bucket_count_chart = {
        "< 1 BTC"     => @details_latest.inflow_lt_1_count,
        "1–10 BTC"    => @details_latest.inflow_1_10_count,
        "10–100 BTC"  => @details_latest.inflow_10_100_count,
        "100–500 BTC" => @details_latest.inflow_100_500_count,
        "> 500 BTC"   => @details_latest.inflow_gt_500_count
      }

      @withdrawal_bucket_count_chart = {
        "< 1 BTC"     => @details_latest.outflow_lt_1_count,
        "1–10 BTC"    => @details_latest.outflow_1_10_count,
        "10–100 BTC"  => @details_latest.outflow_10_100_count,
        "100–500 BTC" => @details_latest.outflow_100_500_count,
        "> 500 BTC"   => @details_latest.outflow_gt_500_count
      }

      @deposit_buckets = [
        {
          label: "< 1 BTC",
          count: @details_latest.inflow_lt_1_count,
          btc: @details_latest.inflow_lt_1_btc.to_d
        },
        {
          label: "1–10 BTC",
          count: @details_latest.inflow_1_10_count,
          btc: @details_latest.inflow_1_10_btc.to_d
        },
        {
          label: "10–100 BTC",
          count: @details_latest.inflow_10_100_count,
          btc: @details_latest.inflow_10_100_btc.to_d
        },
        {
          label: "100–500 BTC",
          count: @details_latest.inflow_100_500_count,
          btc: @details_latest.inflow_100_500_btc.to_d
        },
        {
          label: "> 500 BTC",
          count: @details_latest.inflow_gt_500_count,
          btc: @details_latest.inflow_gt_500_btc.to_d
        }
      ]

      @withdrawal_buckets = [
        {
          label: "< 1 BTC",
          count: @details_latest.outflow_lt_1_count,
          btc: @details_latest.outflow_lt_1_btc.to_d
        },
        {
          label: "1–10 BTC",
          count: @details_latest.outflow_1_10_count,
          btc: @details_latest.outflow_1_10_btc.to_d
        },
        {
          label: "10–100 BTC",
          count: @details_latest.outflow_10_100_count,
          btc: @details_latest.outflow_10_100_btc.to_d
        },
        {
          label: "100–500 BTC",
          count: @details_latest.outflow_100_500_count,
          btc: @details_latest.outflow_100_500_btc.to_d
        },
        {
          label: "> 500 BTC",
          count: @details_latest.outflow_gt_500_count,
          btc: @details_latest.outflow_gt_500_btc.to_d
        }
      ]
    else
      @deposit_summary = {
        deposit_count: 0,
        avg_deposit_btc: 0.to_d,
        max_deposit_btc: 0.to_d
      }

      @withdrawal_summary = {
        withdrawal_count: 0,
        avg_withdrawal_btc: 0.to_d,
        max_withdrawal_btc: 0.to_d
      }

      @deposit_bucket_count_chart = {
        "< 1 BTC"     => 0,
        "1–10 BTC"    => 0,
        "10–100 BTC"  => 0,
        "100–500 BTC" => 0,
        "> 500 BTC"   => 0
      }

      @withdrawal_bucket_count_chart = {
        "< 1 BTC"     => 0,
        "1–10 BTC"    => 0,
        "10–100 BTC"  => 0,
        "100–500 BTC" => 0,
        "> 500 BTC"   => 0
      }

      @deposit_buckets = []
      @withdrawal_buckets = []
    end

    # =========================
    # V3 behavior
    # =========================
    @behavior_latest =
      if @latest_day.present?
        ExchangeFlowDayBehavior.find_by(day: @latest_day)
      end

    if @behavior_latest.present?
      @deposit_behavior_ratios = [
        {
          label: "Retail deposit ratio",
          value: @behavior_latest.retail_deposit_ratio.to_d
        },
        {
          label: "Whale deposit ratio",
          value: @behavior_latest.whale_deposit_ratio.to_d
        },
        {
          label: "Institutional deposit ratio",
          value: @behavior_latest.institutional_deposit_ratio.to_d
        }
      ]

      @withdrawal_behavior_ratios = [
        {
          label: "Retail withdrawal ratio",
          value: @behavior_latest.retail_withdrawal_ratio.to_d
        },
        {
          label: "Whale withdrawal ratio",
          value: @behavior_latest.whale_withdrawal_ratio.to_d
        },
        {
          label: "Institutional withdrawal ratio",
          value: @behavior_latest.institutional_withdrawal_ratio.to_d
        }
      ]

      @behavior_scores = [
        {
          label: "Deposit concentration",
          value: @behavior_latest.deposit_concentration_score.to_d
        },
        {
          label: "Withdrawal concentration",
          value: @behavior_latest.withdrawal_concentration_score.to_d
        },
        {
          label: "Distribution score",
          value: @behavior_latest.distribution_score.to_d
        },
        {
          label: "Accumulation score",
          value: @behavior_latest.accumulation_score.to_d
        },
        {
          label: "Behavior score",
          value: @behavior_latest.behavior_score.to_d
        }
      ]

      @deposit_behavior_chart = {
        "Retail"        => pct(@behavior_latest.retail_deposit_ratio),
        "Whale"         => pct(@behavior_latest.whale_deposit_ratio),
        "Institutional" => pct(@behavior_latest.institutional_deposit_ratio)
      }

      @withdrawal_behavior_chart = {
        "Retail"        => pct(@behavior_latest.retail_withdrawal_ratio),
        "Whale"         => pct(@behavior_latest.whale_withdrawal_ratio),
        "Institutional" => pct(@behavior_latest.institutional_withdrawal_ratio)
      }

      @behavior_score_chart = {
        "Deposit concentration"    => pct(@behavior_latest.deposit_concentration_score),
        "Withdrawal concentration" => pct(@behavior_latest.withdrawal_concentration_score),
        "Distribution"             => pct(@behavior_latest.distribution_score),
        "Accumulation"             => pct(@behavior_latest.accumulation_score),
        "Behavior"                 => pct(@behavior_latest.behavior_score)
      }
    else
      @deposit_behavior_ratios = []
      @withdrawal_behavior_ratios = []
      @behavior_scores = []

      @deposit_behavior_chart = {
        "Retail"        => 0,
        "Whale"         => 0,
        "Institutional" => 0
      }

      @withdrawal_behavior_chart = {
        "Retail"        => 0,
        "Whale"         => 0,
        "Institutional" => 0
      }

      @behavior_score_chart = {
        "Deposit concentration"    => 0,
        "Withdrawal concentration" => 0,
        "Distribution"             => 0,
        "Accumulation"             => 0,
        "Behavior"                 => 0
      }
    end

    # =========================
    # V4 capital behavior
    # =========================
    @capital_behavior_latest =
      if @latest_day.present?
        ExchangeFlowDayCapitalBehavior.find_by(day: @latest_day)
      end

    if @capital_behavior_latest.present?
      @deposit_capital_ratios = [
        {
          label: "Retail deposit capital ratio",
          value: @capital_behavior_latest.retail_deposit_capital_ratio.to_d
        },
        {
          label: "Whale deposit capital ratio",
          value: @capital_behavior_latest.whale_deposit_capital_ratio.to_d
        },
        {
          label: "Institutional deposit capital ratio",
          value: @capital_behavior_latest.institutional_deposit_capital_ratio.to_d
        }
      ]

      @withdrawal_capital_ratios = [
        {
          label: "Retail withdrawal capital ratio",
          value: @capital_behavior_latest.retail_withdrawal_capital_ratio.to_d
        },
        {
          label: "Whale withdrawal capital ratio",
          value: @capital_behavior_latest.whale_withdrawal_capital_ratio.to_d
        },
        {
          label: "Institutional withdrawal capital ratio",
          value: @capital_behavior_latest.institutional_withdrawal_capital_ratio.to_d
        }
      ]

      @capital_scores = [
        {
          label: "Capital dominance",
          value: @capital_behavior_latest.capital_dominance_score.to_d
        },
        {
          label: "Whale distribution",
          value: @capital_behavior_latest.whale_distribution_score.to_d
        },
        {
          label: "Whale accumulation",
          value: @capital_behavior_latest.whale_accumulation_score.to_d
        },
        {
          label: "Count / volume divergence",
          value: @capital_behavior_latest.count_volume_divergence_score.to_d
        },
        {
          label: "Capital behavior",
          value: @capital_behavior_latest.capital_behavior_score.to_d
        }
      ]

      @deposit_capital_chart = {
        "Retail"        => pct(@capital_behavior_latest.retail_deposit_capital_ratio),
        "Whale"         => pct(@capital_behavior_latest.whale_deposit_capital_ratio),
        "Institutional" => pct(@capital_behavior_latest.institutional_deposit_capital_ratio)
      }

      @withdrawal_capital_chart = {
        "Retail"        => pct(@capital_behavior_latest.retail_withdrawal_capital_ratio),
        "Whale"         => pct(@capital_behavior_latest.whale_withdrawal_capital_ratio),
        "Institutional" => pct(@capital_behavior_latest.institutional_withdrawal_capital_ratio)
      }

      @capital_score_chart = {
        "Capital dominance"       => pct(@capital_behavior_latest.capital_dominance_score),
        "Whale distribution"      => pct(@capital_behavior_latest.whale_distribution_score),
        "Whale accumulation"      => pct(@capital_behavior_latest.whale_accumulation_score),
        "Count / volume divergence" => pct(@capital_behavior_latest.count_volume_divergence_score),
        "Capital behavior"        => pct(@capital_behavior_latest.capital_behavior_score)
      }
    else
      @deposit_capital_ratios = []
      @withdrawal_capital_ratios = []
      @capital_scores = []

      @deposit_capital_chart = {
        "Retail"        => 0,
        "Whale"         => 0,
        "Institutional" => 0
      }

      @withdrawal_capital_chart = {
        "Retail"        => 0,
        "Whale"         => 0,
        "Institutional" => 0
      }

      @capital_score_chart = {
        "Capital dominance"         => 0,
        "Whale distribution"        => 0,
        "Whale accumulation"        => 0,
        "Count / volume divergence" => 0,
        "Capital behavior"          => 0
      }
    end
  end

  private

  def fill_daily_series(data, days:)
    start_day = Date.current - (days - 1)

    (start_day..Date.current).each_with_object({}) do |day, h|
      h[day] = data[day] || 0
    end
  end

  def pct(value)
    (value.to_d * 100).round(2)
  end
end