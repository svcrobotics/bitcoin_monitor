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

    PROGRESS_EVERY = 500

    def self.call(limit: nil, job_run: nil)
      new(limit: limit, job_run: job_run).call
    end

    def initialize(limit: nil, job_run: nil)
      @limit = limit
      @job_run = job_run
      @created = 0
      @updated = 0
      @skipped = 0
      @processed = 0
      @total = nil
      @current_cluster_id = nil
    end

    def call
      scope = ClusterProfile.order(:cluster_id)
      scope = scope.limit(@limit) if @limit.present?

      @total = @limit || scope.count

      progress!("starting", 5)

      scope.find_each do |profile|
        @current_cluster_id = profile.cluster_id
        refresh_profile(profile)
        @processed += 1

        progress!("refreshing", computed_pct) if (@processed % PROGRESS_EVERY).zero?
      end

      progress!("done", 100)

      {
        ok: true,
        processed: @processed,
        total: @total,
        created: @created,
        updated: @updated,
        skipped: @skipped
      }
    end

    private

    def refresh_profile(profile)
      rows =
        labels_for(profile).map do |attrs|
          now = Time.current

          {
            cluster_id: profile.cluster_id,
            label: attrs[:label],
            source: "cluster_profile",
            confidence: attrs[:confidence],
            metadata: attrs[:metadata],
            first_seen_at: now,
            last_seen_at: now,
            created_at: now,
            updated_at: now
          }
        end

      return if rows.empty?

      ActorLabel.upsert_all(
        rows,
        unique_by: :index_actor_labels_on_cluster_id_and_label_and_source,
        update_only: %i[
          confidence
          metadata
          last_seen_at
        ]
      )

      @updated += rows.size
    rescue StandardError => e
      @skipped += 1

      Rails.logger.warn(
        "[actor_labels] skipped cluster_id=#{profile.cluster_id} " \
        "#{e.class}: #{e.message}"
      )

      puts "[actor_labels] skipped cluster_id=#{profile.cluster_id} #{e.class}: #{e.message}"
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

    def computed_pct
      return 5 if @total.to_i <= 0

      progress = (@processed.to_f / @total.to_f * 95).round(1)
      [[5 + progress, 99].min, 5].max
    end

    def progress!(label, pct)
      return unless @job_run

      JobRunner.progress!(
        @job_run,
        pct: pct,
        label: label,
        meta: {
          limit: @limit,
          processed: @processed,
          total: @total,
          created: @created,
          updated: @updated,
          skipped: @skipped,
          current_cluster_id: @current_cluster_id
        }
      )
    end
  end
end