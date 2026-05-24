# frozen_string_literal: true

module Actors
  class RefreshMetrics
    DEFAULT_LIMIT = 1_000

    def self.call(limit: DEFAULT_LIMIT)
      new(limit: limit).call
    end

    def initialize(limit:)
      @limit = limit
      @created = 0
      @updated = 0
      @skipped = 0
    end

    def call
      Cluster.order(:id).limit(@limit).find_each do |cluster|
        refresh_cluster(cluster)
      end

      {
        ok: true,
        created: @created,
        updated: @updated,
        skipped: @skipped
      }
    end

    private

    def refresh_cluster(cluster)
      addresses = Address.where(cluster_id: cluster.id)

      first_seen = addresses.minimum(:first_seen_height)
      last_seen  = addresses.maximum(:last_seen_height)

      metric = ActorMetric.find_or_initialize_by(cluster_id: cluster.id)

      metric.address_count        = addresses.count
      metric.total_tx_count       = addresses.sum(:tx_count)
      metric.total_received_sats  = addresses.sum(:total_received_sats)
      metric.total_sent_sats      = addresses.sum(:total_sent_sats)

      metric.first_seen_height    = first_seen
      metric.last_seen_height     = last_seen

      metric.activity_span_blocks =
        if first_seen && last_seen
          last_seen - first_seen
        end

      metric.exchange_score = exchange_score(metric)

      metric.new_record? ? @created += 1 : @updated += 1
      metric.save!
    rescue StandardError => e
      @skipped += 1

      Rails.logger.warn(
        "[actors] metric skipped cluster_id=#{cluster.id} " \
        "#{e.class}: #{e.message}"
      )
    end

    def exchange_score(metric)
      score = 0

      score += 25 if metric.address_count.to_i >= 1_000
      score += 25 if metric.total_tx_count.to_i >= 10_000
      score += 25 if metric.activity_span_blocks.to_i >= 1_000
      score += 25 if metric.total_sent_sats.to_i >= 10_000_000_000

      score
    end
  end
end
