# frozen_string_literal: true

module Actors
  class RefreshExchangeLabelsFromMetrics
    MIN_EXCHANGE_SCORE = 100

    def self.call
      new.call
    end

    def initialize
      @created = 0
      @updated = 0
      @skipped = 0
    end

    def call
      ActorMetric
        .where("exchange_score >= ?", MIN_EXCHANGE_SCORE)
        .find_each do |metric|
          refresh_metric(metric)
        end

      {
        ok: true,
        created: @created,
        updated: @updated,
        skipped: @skipped
      }
    end

    private

    def refresh_metric(metric)
      label = ActorLabel.find_or_initialize_by(
        cluster_id: metric.cluster_id,
        label: "exchange_like",
        source: "actor_metric"
      )

      label.confidence = metric.exchange_score
      label.metadata = {
        address_count: metric.address_count,
        total_tx_count: metric.total_tx_count,
        total_sent_sats: metric.total_sent_sats,
        activity_span_blocks: metric.activity_span_blocks,
        score_source: "actor_metrics_v1"
      }

      label.first_seen_at ||= Time.current
      label.last_seen_at = Time.current

      label.new_record? ? @created += 1 : @updated += 1
      label.save!
    rescue StandardError => e
      @skipped += 1

      Rails.logger.warn(
        "[actors] exchange label from metric skipped " \
        "cluster_id=#{metric.cluster_id} #{e.class}: #{e.message}"
      )
    end
  end
end
