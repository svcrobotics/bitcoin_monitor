# frozen_string_literal: true

module ActorLabels
  class StrictWriter
    RULE_SET = ActorLabels::StrictRuleSetV2
    SOURCE = RULE_SET::SOURCE

    def self.call(profile:, cluster_tip:, dry_run: true)
      new(
        profile: profile,
        cluster_tip: cluster_tip,
        dry_run: dry_run
      ).call
    end

    def initialize(profile:, cluster_tip:, dry_run:)
      @profile = profile
      @cluster_tip = cluster_tip.to_i
      @dry_run = dry_run
    end

    def call
      result =
        RULE_SET.call(
          profile: profile,
          cluster_tip: cluster_tip
        )

      expected_labels =
        result[:eligible] ? Array(result[:labels]) : []

      expected_names =
        expected_labels.map do |label|
          label.fetch(:label)
        end

      existing_scope =
        ActorLabel.where(
          actor_profile_id: profile.id,
          source: SOURCE
        )

      obsolete_scope =
        if expected_names.empty?
          existing_scope
        else
          existing_scope.where.not(
            label: expected_names
          )
        end

      expected_deleted_labels =
        obsolete_scope.pluck(:label)

      written_labels = []
      deleted_labels = []

      unless dry_run
        deleted_labels =
          expected_deleted_labels

        obsolete_scope.delete_all

        written_labels =
          expected_labels.map do |label_data|
            write_label(
              label_data: label_data,
              rule_result: result
            )
          end
      end

      {
        ok: true,
        dry_run: dry_run,
        actor_profile_id: profile.id,
        cluster_id: profile.cluster_id,
        eligible: result[:eligible],
        reason: result[:reason],
        profile_lag: result[:profile_lag],
        expected_labels: expected_names,
        expected_deleted_labels:
          expected_deleted_labels,
        written_labels: written_labels,
        deleted_labels: deleted_labels
      }
    end

    private

    attr_reader :profile, :cluster_tip, :dry_run

    def write_label(label_data:, rule_result:)
      attributes = {
        actor_profile_id: profile.id,
        confidence:
          label_data.fetch(:confidence),

        metadata: {
          strict: true,

          profile_version:
            ActorLabels::StrictRuleSetV2::PROFILE_VERSION,

          rule_version:
            label_data.fetch(:rule_version),

          reason:
            label_data.fetch(:reason),

          profile_height:
            profile.last_computed_height,

          cluster_tip:
            cluster_tip,

          profile_lag:
            rule_result[:profile_lag],

          profile_cluster_composition_version:
            profile.cluster_composition_version,

          cluster_composition_version:
            profile.cluster.composition_version,

          evidence:
            rule_result[:evidence]
        },

        last_seen_at:
          Time.current
      }

      label =
        ActorLabel.find_or_initialize_by(
          cluster_id: profile.cluster_id,
          label: label_data.fetch(:label),
          source: SOURCE
        )

      created = label.new_record?

      label.first_seen_at ||= Time.current
      label.assign_attributes(attributes)
      label.save!

      {
        id: label.id,
        label: label.label,
        confidence: label.confidence,
        created: created
      }
    end
  end
end
