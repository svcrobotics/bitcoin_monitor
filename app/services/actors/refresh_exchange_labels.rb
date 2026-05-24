# frozen_string_literal: true

module Actors
  class RefreshExchangeLabels
    DEFAULT_LIMIT = 10_000

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
      result = Actors::ExchangeScoreQuery.call(cluster_id: cluster.id)
      return unless result[:exchange_like]

      label = ActorLabel.find_or_initialize_by(
        cluster_id: cluster.id,
        label: "exchange_like",
        source: "actor_score"
      )

      label.confidence = result[:exchange_score]
      label.metadata = result.except(:exchange_like)
      label.first_seen_at ||= Time.current
      label.last_seen_at = Time.current

      label.new_record? ? @created += 1 : @updated += 1
      label.save!
    rescue StandardError => e
      @skipped += 1
      Rails.logger.warn("[actors] exchange label skipped cluster_id=#{cluster.id} #{e.class}: #{e.message}")
    end
  end
end
