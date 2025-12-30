# frozen_string_literal: true

class WhaleAlertsController < ApplicationController
  WANTED_TYPES = %w[consolidation distribution batching].freeze

  def index
    @mode         = params[:mode].presence_in(%w[interesting all]) || "interesting"
    @type         = params[:type].presence
    @min_btc      = params[:min_btc].presence
    @sort         = params[:sort].presence_in(%w[recent score]) || "recent"
    @min_score    = params[:min_score].presence
    @min_exchange = params[:min_exchange].presence

    @btc_eur = BtcPrice.eur

    base = WhaleAlert.all
    base = base.where.not(alert_type: "other") if @mode == "interesting"

    base = base.by_type(@type)
               .min_btc(@min_btc)
               .min_score(@min_score)
               .min_exchange(@min_exchange)
               .sorted(@sort)

    @alerts = base.limit(500)

    base_for_agg = base.unscope(:order)

    @counts = base_for_agg.group(:alert_type).count

    build_volume_points!(scope: base_for_agg, days_back: 14)
    build_stacked_counts!(scope: base_for_agg, days_back: 14)

    build_kpis_today!(scope: base_for_agg)          # ✅ KPIs filtrés
    build_counts_summary!(days_back: 14)
  end

  private

  def normalize_to_date(key)
    case key
    when Date then key
    when Time, DateTime, ActiveSupport::TimeWithZone then key.to_date
    else Date.parse(key.to_s)
    end
  rescue ArgumentError
    key
  end

  def build_volume_points!(scope:, days_back:)
    to_day   = Time.current.to_date
    from_day = to_day - (days_back - 1)
    days     = (from_day..to_day).to_a

    raw_btc = scope
      .where(block_time: from_day.beginning_of_day..to_day.end_of_day)
      .group("DATE(block_time)")
      .sum(:total_out_btc)

    raw_btc = raw_btc.transform_keys { |k| normalize_to_date(k) }

    @volume_points = []
    prev = nil

    days.each do |day|
      btc = (raw_btc[day] || 0).to_d

      delta_pct = ((btc - prev) / prev) * 100 if prev&.positive?

      @volume_points << { day: day, btc: btc, eur: (@btc_eur ? (btc * @btc_eur) : nil), delta_pct: delta_pct }
      prev = btc
    end
  end

  def build_stacked_counts!(scope:, days_back:)
    to_day   = Time.current.to_date
    from_day = to_day - (days_back - 1)

    days  = (from_day..to_day).to_a
    types = WhaleAlert::TYPES.map(&:to_s)

    raw = scope
      .where(block_time: from_day.beginning_of_day..to_day.end_of_day)
      .group("DATE(block_time)", :alert_type)
      .count

    raw = raw.transform_keys { |(k_day, k_type)| [normalize_to_date(k_day), k_type.to_s] }

    @chart_counts = []
    prev_total = nil

    days.each do |day|
      by_type = types.index_with { |t| (raw[[day, t]] || 0).to_i }
      total   = by_type.values.sum

      delta_pct = ((total - prev_total).to_f / prev_total) * 100 if prev_total&.positive?

      @chart_counts << { day: day, by_type: by_type, total: total, delta_pct: delta_pct }
      prev_total = total
    end
  end

  def build_kpis_today!(scope:)
    today_range = Time.current.beginning_of_day..Time.current.end_of_day
    rel = scope.where(block_time: today_range)

    @kpi_today_total_btc = rel.sum(:total_out_btc).to_d
    @kpi_today_interesting_count = rel.where.not(alert_type: "other").count
    @kpi_today_top = rel.order(score: :desc, total_out_btc: :desc).first
  end

  def build_counts_summary!(days_back:)
    to_time   = Time.current
    from_time = (to_time - (days_back - 1).days).beginning_of_day
    range     = from_time..to_time
    today_range = Time.current.beginning_of_day..Time.current.end_of_day

    @counts_14d =
      WhaleAlert.where(block_time: range, alert_type: WANTED_TYPES).group(:alert_type).count

    @counts_today =
      WhaleAlert.where(block_time: today_range, alert_type: WANTED_TYPES).group(:alert_type).count
  end
end
