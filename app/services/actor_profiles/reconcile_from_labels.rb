# frozen_string_literal: true

module ActorProfiles
  class ReconcileFromLabels
    MIN_CONFIDENCE = 100
    EXCHANGE_LABEL = "exchange_like"

    def self.call
      new.call
    end

    def initialize
      @updated = 0
      @skipped = 0
    end

    def call
      ActorLabel
        .where(label: EXCHANGE_LABEL)
        .where("confidence >= ?", MIN_CONFIDENCE)
        .find_each do |label|
          reconcile(label)
        end

      {
        ok: true,
        updated: @updated,
        skipped: @skipped
      }
    end

    private

    def reconcile(label)
      profile = ActorProfile.find_by(cluster_id: label.cluster_id)

      return skip unless profile
      return skip unless profile.classification.blank? || profile.classification == "unknown"

      profile.classification = EXCHANGE_LABEL
      profile.metadata = (profile.metadata || {}).merge(
        "classification_reconciled_from_label" => true,
        "reconciled_label_source" => label.source,
        "reconciled_label_confidence" => label.confidence,
        "reconciled_at" => Time.current
      )
      profile.save!

      @updated += 1
    rescue StandardError => e
      @skipped += 1
      Rails.logger.warn(
        "[actor_profiles] reconcile skipped cluster_id=#{label.cluster_id} #{e.class}: #{e.message}"
      )
    end

    def skip
      @skipped += 1
      nil
    end
  end
end
