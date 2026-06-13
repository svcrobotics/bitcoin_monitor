# app/services/cluster_metrics_builder.rb
class ClusterMetricsBuilder
  def self.call(cluster, snapshot_date: Date.current)
    new(cluster, snapshot_date: snapshot_date).call
  end

  def initialize(cluster, snapshot_date: Date.current)
    @cluster = cluster
    @snapshot_date = snapshot_date.to_date
  end

  def call
    profile = @cluster.cluster_profile
    return nil unless profile.present?

    cluster_age_blocks = [profile.last_seen_height.to_i - profile.first_seen_height.to_i, 0].max

    tx_count_24h =
      if cluster_age_blocks <= 144
        profile.tx_count.to_i
      else
        [(profile.tx_count.to_f / [cluster_age_blocks, 1].max) * 144, profile.tx_count.to_i].min.round
      end

    tx_count_7d =
      if cluster_age_blocks <= 1008
        profile.tx_count.to_i
      else
        [(profile.tx_count.to_f / [cluster_age_blocks, 1].max) * 1008, profile.tx_count.to_i].min.round
      end

    sent_sats_24h =
      if cluster_age_blocks <= 144
        profile.total_sent_sats.to_i
      else
        [(profile.total_sent_sats.to_f / [cluster_age_blocks, 1].max) * 144, profile.total_sent_sats.to_i].min.round
      end

    sent_sats_7d =
      if cluster_age_blocks <= 1008
        profile.total_sent_sats.to_i
      else
        [(profile.total_sent_sats.to_f / [cluster_age_blocks, 1].max) * 1008, profile.total_sent_sats.to_i].min.round
      end

    activity_score = build_activity_score(tx_count_24h, tx_count_7d, sent_sats_24h, sent_sats_7d)

    metric = ClusterMetric.find_or_initialize_by(
      cluster_id: @cluster.id,
      snapshot_date: @snapshot_date
    )

    metric.update!(
      tx_count_24h: tx_count_24h,
      tx_count_7d: tx_count_7d,
      sent_sats_24h: sent_sats_24h,
      sent_sats_7d: sent_sats_7d,
      activity_score: activity_score
    )

    metric
  end

  private

  def build_activity_score(tx_24h, tx_7d, sats_24h, sats_7d)
    score = 0

    score +=
      if tx_24h > 1000
        35
      elsif tx_24h > 100
        25
      elsif tx_24h > 10
        15
      elsif tx_24h > 0
        8
      else
        0
      end

    score +=
      if tx_7d > 5000
        20
      elsif tx_7d > 1000
        15
      elsif tx_7d > 100
        10
      elsif tx_7d > 0
        5
      else
        0
      end

    btc_24h = sats_24h.to_f / 100_000_000.0
    btc_7d  = sats_7d.to_f / 100_000_000.0

    score +=
      if btc_24h > 1000
        25
      elsif btc_24h > 100
        18
      elsif btc_24h > 10
        10
      elsif btc_24h > 0
        4
      else
        0
      end

    score +=
      if btc_7d > 5000
        20
      elsif btc_7d > 1000
        15
      elsif btc_7d > 100
        10
      elsif btc_7d > 0
        5
      else
        0
      end

    [[score, 0].max, 100].min
  end
end