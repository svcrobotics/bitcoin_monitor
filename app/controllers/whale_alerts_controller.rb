class WhaleAlertsController < ApplicationController
  def index
    @mode    = params[:mode].presence_in(%w[interesting all]) || "interesting"
    @type    = params[:type].presence
    @min_btc = params[:min_btc].presence

    base = WhaleAlert
    base = base.where.not(alert_type: "other") if @mode == "interesting"
    base = base.where(alert_type: @type) if @type.present?
    base = base.where("total_out_btc >= ?", @min_btc.to_d) if @min_btc.present?
    base = base.order(block_time: :desc, created_at: :desc)

    @btc_eur = BtcPrice.eur

    @sort      = params[:sort].presence_in(%w[recent score]) || "recent"
    @min_score = params[:min_score].presence

    base = WhaleAlert
      .then { |q| @mode == "interesting" ? q.where.not(alert_type: "other") : q }
      .by_type(@type)
      .min_btc(@min_btc)
      .min_score(@min_score)
      .sorted(@sort)

    @alerts = base.limit(500)
    @counts = base.unscope(:order).group(:alert_type).count

  end
end
