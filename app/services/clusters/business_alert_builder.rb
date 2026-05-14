# frozen_string_literal: true

module Clusters
  class BusinessAlertBuilder
    DEFAULT_LIMIT = 200

    def self.call(snapshot_date: Date.current, limit: DEFAULT_LIMIT)
      new(snapshot_date: snapshot_date, limit: limit).call
    end

    def initialize(snapshot_date:, limit:)
      @snapshot_date = snapshot_date.to_date
      @limit = limit.to_i
    end

    def call
      scanned = 0
      emitted = 0

      metrics.find_each do |metric|
        scanned += 1

        profile = ClusterProfile.find_by(cluster_id: metric.cluster_id)
        next unless profile

        emit_large_outflow(metric, profile)
        emit_activity_spike(metric, profile)
        emit_whale_activity(metric, profile)

        build_cluster_reactivation_alerts(metric, profile).each do |alert|
          write_event(
            cluster_id: metric.cluster_id,
            signal_type: alert[:signal_type],
            severity: alert[:severity],
            score: alert[:score],
            amount_btc: alert[:amount_btc],
            tx_count: alert[:tx_count],
            address_count: alert[:address_count]
          )

          emitted += 1
        end
      end

      {
        ok: true,
        snapshot_date: snapshot_date,
        scanned: scanned,
        emitted: emitted
      }
    end

    private

    attr_reader :snapshot_date, :limit

    def metrics
      ClusterMetric
        .where(snapshot_date: snapshot_date)
        .order(activity_score: :desc)
        .limit(limit)
    end

    def build_cluster_reactivation_alerts(metric, profile)
      return [] unless profile.present?

      state = ClusterActivityState.find_by(cluster_id: metric.cluster_id)
      return [] unless state.present?

      inactive_seconds = state.inactive_seconds.to_i
      inactive_days = inactive_seconds / 1.day.to_f

      tx_24h = metric.tx_count_24h.to_i
      btc_24h = sats_to_btc(metric.sent_sats_24h)

      return [] if inactive_seconds < 24.hours.to_i
      return [] if tx_24h < 20
      return [] if btc_24h < 100

      severity =
        if inactive_days >= 30 && btc_24h >= 1_000
          "high"
        elsif inactive_days >= 7 || btc_24h >= 250
          "medium"
        else
          "low"
        end

      score =
        [
          (btc_24h / 10).round,
          (inactive_days * 2).round,
          40
        ].max.clamp(0, 100)

      [
        {
          signal_type: "cluster_reactivation",
          severity: severity,
          score: score,
          amount_btc: btc_24h,
          tx_count: tx_24h,
          address_count: profile.cluster_size.to_i
        }
      ]
    end

    def emit_large_outflow(metric, profile)
      btc_24h = sats_to_btc(metric.sent_sats_24h)

      return if btc_24h < 100

      severity =
        if btc_24h >= 1_000
          "high"
        elsif btc_24h >= 250
          "medium"
        else
          "low"
        end

      score =
        [
          (btc_24h / 10).round,
          60
        ].max.clamp(0, 100)

      write_event(
        cluster_id: metric.cluster_id,
        signal_type: "large_outflow",
        severity: severity,
        score: score,
        amount_btc: btc_24h,
        tx_count: metric.tx_count_24h,
        address_count: profile.cluster_size
      )
    end

    def emit_activity_spike(metric, profile)
      tx_24h = metric.tx_count_24h.to_i
      tx_7d = metric.tx_count_7d.to_i

      return if tx_24h < 50

      avg_daily_7d = tx_7d / 7.0
      return if avg_daily_7d.positive? && tx_24h < avg_daily_7d * 3

      severity =
        if tx_24h >= 500
          "high"
        else
          "medium"
        end

      score = [[tx_24h / 5, 100].min, 55].max.to_i

      write_event(
        cluster_id: metric.cluster_id,
        signal_type: "activity_spike",
        severity: severity,
        score: score,
        amount_btc: sats_to_btc(metric.sent_sats_24h),
        tx_count: tx_24h,
        address_count: profile.cluster_size
      )
    end

    def emit_whale_activity(metric, profile)
      btc_24h = sats_to_btc(metric.sent_sats_24h)
      total_sent_btc = sats_to_btc(profile.total_sent_sats)

      return if btc_24h < 500
      return if total_sent_btc < 1_000

      severity =
        if btc_24h >= 2_000
          "high"
        else
          "medium"
        end

      score = [[btc_24h / 20, 100].min, 70].max.to_i

      write_event(
        cluster_id: metric.cluster_id,
        signal_type: "whale_cluster_activity",
        severity: severity,
        score: score,
        amount_btc: btc_24h,
        tx_count: metric.tx_count_24h,
        address_count: profile.cluster_size
      )
    end

    def write_event(cluster_id:, signal_type:, severity:, score:, amount_btc:, tx_count:, address_count:)
      activity_state =
        Clusters::ActivityTracker.call(
          cluster_id: cluster_id,
          height: latest_height
        )

      Clusters::ClickHouseEventWriter.call(
        cluster_id: cluster_id,
        block_height: latest_height,
        signal_type: signal_type,
        severity: severity,
        score: score,
        amount_btc: amount_btc,
        tx_count: tx_count,
        address_count: address_count,
        source: "cluster_business"
      )

      activity_state
    end

    def latest_height
      @latest_height ||= ScannerCursor.find_by(name: "cluster_scan")&.last_blockheight.to_i
    end

    def sats_to_btc(value)
      value.to_f / 100_000_000.0
    end
  end
end