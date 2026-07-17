# frozen_string_literal: true

module ActorLabels
  class StrictWriter
    RULE_SET = ActorLabels::StrictRuleSet
    SOURCE = RULE_SET::SOURCE

    def self.call(snapshot:, dry_run: true)
      new(
        snapshot: snapshot,
        dry_run: dry_run
      ).call
    end

    def initialize(snapshot:, dry_run:)
      @snapshot = snapshot
      @dry_run = dry_run
    end

    def call
      result =
        RULE_SET.call(
          snapshot: snapshot
        )

      return ineligible_result(result) unless result[:eligible]

      expected_labels =
        Array(result[:labels])

      expected_names =
        expected_labels.map do |label|
          label.fetch(:label)
        end

      existing_scope =
        ActorLabel.where(
          cluster_id: snapshot.cluster_id,
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
        ActorLabel.transaction do
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
      end

      {
        ok: true,
        dry_run: dry_run,
        eligible: true,
        reason: nil,

        actor_behavior_snapshot_id:
          snapshot.id,

        actor_profile_id:
          snapshot.actor_profile_id,

        cluster_id:
          snapshot.cluster_id,

        expected_labels:
          expected_names,

        expected_deleted_labels:
          expected_deleted_labels,

        written_labels:
          written_labels,

        deleted_labels:
          deleted_labels
      }
    end

    private

    attr_reader :snapshot, :dry_run

    def ineligible_result(result)
      {
        ok: true,
        dry_run: dry_run,
        eligible: false,
        reason: result[:reason],

        actor_behavior_snapshot_id:
          snapshot&.id,

        actor_profile_id:
          snapshot&.actor_profile_id,

        cluster_id:
          snapshot&.cluster_id,

        expected_labels: [],
        expected_deleted_labels: [],
        written_labels: [],
        deleted_labels: []
      }
    end

    def write_label(label_data:, rule_result:)
      now =
        Time.current

      label =
        ActorLabel.find_or_initialize_by(
          cluster_id:
            snapshot.cluster_id,

          label:
            label_data.fetch(:label),

          source:
            SOURCE
        )

      created =
        label.new_record?

      label.first_seen_at ||= now

      label.assign_attributes(
        actor_profile_id:
          snapshot.actor_profile_id,

        confidence:
          label_data.fetch(:confidence),

        metadata: {
          strict: true,
          behavior_based: true,

          actor_behavior_snapshot_id:
            snapshot.id,

          behavior_version:
            snapshot.behavior_version,

          behavior_status:
            snapshot.status,

          rule_version:
            label_data.fetch(:rule_version),

          reason:
            label_data.fetch(:reason),

          profile_version:
            snapshot.profile_version,

          profile_height:
            snapshot.profile_height,

          cluster_composition_version:
            snapshot.cluster_composition_version,

          profile_fingerprint:
            snapshot.profile_fingerprint,

          behavior_computed_at:
            snapshot.computed_at,

          evidence:
            rule_result[:evidence]
        },

        last_seen_at:
          now
      )

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
