# frozen_string_literal: true

module ActorLabels
  class RefreshFromClusterProfile
    CLASSIFICATION_LABEL_MAP = {
      "exchange_like" => "exchange_like",
      "whale" => "whale_like",
      "whale_like" => "whale_like",
      "service" => "service_like",
      "service_like" => "service_like",
      "retail" => "retail_like",
      "retail_like" => "retail_like",
      "unknown" => "unknown"
    }.freeze

    def self.call(limit: nil)
      new(limit: limit).call
    end

    def initialize(limit: nil)
      @limit = limit
      @created = 0
      @updated = 0
      @skipped = 0
    end

    def call
      scope = ClusterProfile.order(:cluster_id)
      scope = scope.limit(@limit) if @limit.present?

      scope.find_each do |profile|
        refresh_profile(profile)
      end

      {
        ok: true,
        created: @created,
        updated: @updated,
        skipped: @skipped
      }
    end

    private

    def refresh_profile(profile)
      labels_for(profile).each do |attrs|
        label = ActorLabel.find_or_initialize_by(
          cluster_id: profile.cluster_id,
          label: attrs[:label],
          source: "cluster_profile"
        )

        label.confidence = attrs[:confidence]
        label.metadata = attrs[:metadata]
        label.first_seen_at ||= Time.current
        label.last_seen_at = Time.current

        label.new_record? ? @created += 1 : @updated += 1

        label.save!
      end
    rescue StandardError => e
      @skipped += 1

      Rails.logger.warn(
        "[actor_labels] skipped cluster_id=#{profile.cluster_id} " \
        "#{e.class}: #{e.message}"
      )
    end

    def labels_for(profile)
      labels = []

      classification = profile.classification.to_s
      label_name = CLASSIFICATION_LABEL_MAP[classification]
      score = profile.score.to_i

      if label_name.present?
        labels << {
          label: label_name,
          confidence: normalize_score(score),
          metadata: {
            original_classification: classification,
            score: score
          }
        }
      end

      traits_for(profile).each do |trait|
        mapped_trait = CLASSIFICATION_LABEL_MAP[trait]

        next unless mapped_trait.present?

        labels << {
          label: mapped_trait,
          confidence: normalize_score(score),
          metadata: {
            original_trait: trait,
            score: score
          }
        }
      end

      labels
    end

    def traits_for(profile)
      traits = profile.traits

      case traits
      when Array
        traits.map(&:to_s)
      when String
        traits.split(",").map(&:strip)
      else
        []
      end
    end

    def normalize_score(score)
      [[score, 0].max, 100].min
    end
  end
end