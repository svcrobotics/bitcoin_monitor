# app/services/cluster_signal_engine.rb
class ClusterSignalEngine
  def self.call(cluster, snapshot_date: Date.current)
    new(cluster, snapshot_date: snapshot_date).call
  end

  def initialize(cluster, snapshot_date: Date.current)
    @cluster = cluster
    @snapshot_date = snapshot_date.to_date
  end

  def call
    metric = @cluster.cluster_metrics.find_by(snapshot_date: @snapshot_date)
    return [] unless metric.present?

    signals = []
    signals.concat(detect_sudden_activity(metric))
    signals.concat(detect_volume_spike(metric))
    signals.concat(detect_large_transfers(metric))
    signals.concat(detect_cluster_activation(metric))

    persist_signals(signals)
    signals


  end

  private

  def detect_sudden_activity(metric)
    tx_24h = metric.tx_count_24h.to_i
    tx_7d  = metric.tx_count_7d.to_i

    return [] if tx_24h <= 0 || tx_7d <= 0

    # Garde-fous anti faux positifs
    return [] if tx_24h >= tx_7d
    return [] if tx_7d < 300

    avg_daily_7d = tx_7d.to_f / 7.0
    return [] if avg_daily_7d <= 0

    ratio = tx_24h / avg_daily_7d
    return [] if ratio < 2.0

    severity, score =
      if tx_24h >= 1000 && ratio >= 3.0
        ["high", build_score(ratio, floor: 75, ceil: 95, factor: 18)]
      elsif tx_24h >= 300 && ratio >= 2.0
        ["medium", build_score(ratio, floor: 60, ceil: 85, factor: 16)]
      else
        return []
      end

    [build_signal(
      type: "sudden_activity",
      severity: severity,
      score: score,
      metadata: {
        tx_24h: tx_24h,
        tx_7d: tx_7d,
        avg_daily_7d: avg_daily_7d.round(2),
        ratio_24h_vs_7d: ratio.round(2)
      }
    )]
  end

  def detect_volume_spike(metric)
    sats_24h = metric.sent_sats_24h.to_i
    sats_7d  = metric.sent_sats_7d.to_i

    return [] if sats_24h <= 0 || sats_7d <= 0

    # Garde-fous anti faux positifs
    return [] if sats_24h >= sats_7d
    return [] if sats_7d < 10_000_000_000 # 100 BTC sur 7j

    avg_daily_7d_sats = sats_7d.to_f / 7.0
    return [] if avg_daily_7d_sats <= 0

    ratio = sats_24h / avg_daily_7d_sats
    return [] if ratio < 2.0

    btc_24h = sats_24h.to_f / 100_000_000.0
    btc_7d  = sats_7d.to_f / 100_000_000.0
    avg_daily_7d_btc = avg_daily_7d_sats / 100_000_000.0

    severity, score =
      if btc_24h >= 500 && ratio >= 3.0
        ["high", build_score(ratio, floor: 75, ceil: 95, factor: 18)]
      elsif btc_24h >= 50 && ratio >= 2.0
        ["medium", build_score(ratio, floor: 60, ceil: 85, factor: 16)]
      else
        return []
      end

    [build_signal(
      type: "volume_spike",
      severity: severity,
      score: score,
      metadata: {
        btc_24h: btc_24h.round(8),
        btc_7d: btc_7d.round(8),
        avg_daily_7d_btc: avg_daily_7d_btc.round(8),
        ratio_24h_vs_7d: ratio.round(2)
      }
    )]
  end

  def build_score(ratio, floor:, ceil:, factor:)
    raw = (ratio * factor).round
    [[raw, floor].max, ceil].min
  end

  def build_signal(type:, severity:, score:, metadata:)
    {
      cluster_id: @cluster.id,
      snapshot_date: @snapshot_date,
      signal_type: type,
      severity: severity,
      score: score,
      metadata: metadata
    }
  end

  def persist_signals(signals)
    ClusterSignal.where(
      cluster_id: @cluster.id,
      snapshot_date: @snapshot_date
    ).delete_all

    signals.each do |attrs|
      ClusterSignal.create!(attrs)
    end

    signals
  end

  def detect_large_transfers(metric)
    btc_24h = metric.sent_sats_24h.to_f / 100_000_000

    return [] if btc_24h < 500
    return [] if metric.tx_count_24h > 50

    [build_signal(
      type: "large_transfers",
      severity: "high",
      score: 90,
      metadata: {
        btc_24h: btc_24h.round(4),
        tx_24h: metric.tx_count_24h
      }
    )]
  end

  def detect_cluster_activation(metric)
    tx_24h = metric.tx_count_24h.to_i
    tx_7d  = metric.tx_count_7d.to_i

    return [] if tx_7d > 200
    return [] if tx_24h < 200

    [build_signal(
      type: "cluster_activation",
      severity: "medium",
      score: 80,
      metadata: {
        tx_24h: tx_24h,
        tx_7d: tx_7d
      }
    )]
  end
end