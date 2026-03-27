# frozen_string_literal: true

class ClusterSignalsController < ApplicationController
  def index
    @date = ClusterSignal.maximum(:snapshot_date)
    @signals = build_scope
  end

  def top
    @date = ClusterSignal.maximum(:snapshot_date)
    @top_clusters = build_top_clusters
  end

  private

  def build_scope
    return [] unless @date.present?

    scope = ClusterSignal
      .includes(cluster: :addresses)
      .where(snapshot_date: @date)

    scope = scope.where(severity: params[:severity]) if params[:severity].present?
    scope = scope.where(signal_type: params[:type]) if params[:type].present?

    scope
      .order(score: :desc, id: :desc)
      .limit(limit_param)
  end

  def build_top_clusters
    return [] unless @date.present?

    signals = ClusterSignal
      .includes(cluster: [:addresses, :cluster_profile])
      .where(snapshot_date: @date)
      .order(score: :desc, id: :desc)

    grouped = signals.group_by(&:cluster)

    grouped.map do |cluster, cluster_signals|
      next if cluster.blank?

      cluster_profile = cluster.cluster_profile
      best_address = pick_best_address(cluster)

      total_score = cluster_signals.sum { |signal| signal.score.to_i }
      max_score = cluster_signals.map { |signal| signal.score.to_i }.max || 0
      high_count = cluster_signals.count { |signal| signal.severity.to_s == "high" }
      medium_count = cluster_signals.count { |signal| signal.severity.to_s == "medium" }
      signal_types = cluster_signals.map { |signal| signal.signal_type.to_s }.uniq

      {
        cluster: cluster,
        cluster_profile: cluster_profile,
        best_address: best_address,
        signals: cluster_signals.sort_by { |signal| [-signal.score.to_i, -signal.id.to_i] },
        total_score: total_score,
        max_score: max_score,
        high_count: high_count,
        medium_count: medium_count,
        signal_count: cluster_signals.size,
        signal_types: signal_types
      }
    end.compact.sort_by do |row|
      [
        -row[:total_score].to_i,
        -row[:high_count].to_i,
        -row[:max_score].to_i,
        -row[:signal_count].to_i,
        row[:cluster].id.to_i
      ]
    end.first(limit_param)
  end

  def pick_best_address(cluster)
    cluster.addresses
      .order(total_sent_sats: :desc, tx_count: :desc, id: :asc)
      .first
  end

  def limit_param
    value = params[:limit].to_i
    return 50 if value <= 0

    [value, 200].min
  end
end