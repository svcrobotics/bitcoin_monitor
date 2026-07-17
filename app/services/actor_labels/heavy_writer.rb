# frozen_string_literal: true

module ActorLabels
  class HeavyWriter
    RULE_SET =
      ActorLabels::HeavyRuleSet

    SOURCE =
      RULE_SET::SOURCE

    def self.call(
      snapshot:,
      dry_run: true
    )
      new(
        snapshot:
          snapshot,

        dry_run:
          dry_run
      ).call
    end

    def initialize(
      snapshot:,
      dry_run:
    )
      @snapshot =
        snapshot

      @dry_run =
        dry_run
    end

    def call
      result =
        RULE_SET.call(
          snapshot:
            snapshot
        )

      return ineligible_result(
        result
      ) unless result[:eligible]

      expected_labels =
        Array(
          result[:labels]
        )

      expected_names =
        expected_labels.map do |label|
          label.fetch(
            :label
          )
        end

      existing_scope =
        ActorLabel.where(
          cluster_id:
            snapshot.cluster_id,

          source:
            SOURCE
        )

      obsolete_scope =
        if expected_names.empty?
          existing_scope
        else
          existing_scope.where.not(
            label:
              expected_names
          )
        end

      expected_deleted_labels =
        obsolete_scope.pluck(
          :label
        )

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
                label_data:
                  label_data,

                rule_result:
                  result
              )
            end
        end
      end

      {
        ok: true,
        dry_run: dry_run,
        eligible: true,
        reason: nil,

        actor_behavior_heavy_snapshot_id:
          snapshot.id,

        actor_profile_id:
          snapshot.actor_profile_id,

        source_cluster_id:
          snapshot.cluster_id,

        downstream_cluster_id:
          snapshot.downstream_cluster_id,

        expected_labels:
          expected_names,

        expected_deleted_labels:
          expected_deleted_labels,

        written_labels:
          written_labels,

        deleted_labels:
          deleted_labels
      }
    rescue StandardError => error
      validation_errors =
        if error.respond_to?(:record) &&
           error.record.respond_to?(:errors)
          error.record.errors.to_hash(
            true
          )
        else
          {}
        end

      {
        ok: false,
        dry_run: dry_run,
        eligible: false,
        reason: :write_failed,

        actor_behavior_heavy_snapshot_id:
          snapshot&.id,

        source_cluster_id:
          snapshot&.cluster_id,

        error_class:
          error.class.name,

        error_message:
          error.message,

        validation_errors:
          validation_errors,

        expected_labels: [],
        written_labels: [],
        deleted_labels: []
      }
    end

    private

    attr_reader(
      :snapshot,
      :dry_run
    )

    def ineligible_result(result)
      {
        ok: true,
        dry_run: dry_run,
        eligible: false,
        reason: result[:reason],

        actor_behavior_heavy_snapshot_id:
          snapshot&.id,

        actor_profile_id:
          snapshot&.actor_profile_id,

        source_cluster_id:
          snapshot&.cluster_id,

        downstream_cluster_id:
          snapshot&.downstream_cluster_id,

        expected_labels: [],
        expected_deleted_labels: [],
        written_labels: [],
        deleted_labels: []
      }
    end

    def write_label(
      label_data:,
      rule_result:
    )
      now =
        Time.current

      label =
        ActorLabel.find_or_initialize_by(
          cluster_id:
            snapshot.cluster_id,

          label:
            label_data.fetch(
              :label
            ),

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
          label_data.fetch(
            :confidence
          ),

        metadata: {
          strict: false,
          heavy: true,
          behavior_based: true,

          actor_behavior_heavy_snapshot_id:
            snapshot.id,

          source_cluster_id:
            snapshot.cluster_id,

          downstream_cluster_id:
            snapshot.downstream_cluster_id,

          analysis_kind:
            snapshot.analysis_kind,

          heavy_version:
            snapshot.heavy_version,

          heavy_status:
            snapshot.status,

          rule_version:
            label_data.fetch(
              :rule_version
            ),

          reason:
            label_data.fetch(
              :reason
            ),

          source_profile_fingerprint:
            snapshot.source_profile_fingerprint,

          source_profile_height:
            snapshot.source_profile_height,

          source_cluster_composition_version:
            snapshot
              .source_cluster_composition_version,

          source_behavior_version:
            snapshot.source_behavior_version,

          window_from_height:
            snapshot.window_from_height,

          window_to_height:
            snapshot.window_to_height,

          evidence_fingerprint:
            snapshot.evidence_fingerprint,

          heavy_computed_at:
            snapshot.computed_at,

          evidence:
            rule_result.fetch(
              :evidence
            )
        },

        last_seen_at:
          now
      )

      label.save!

      {
        id:
          label.id,

        label:
          label.label,

        confidence:
          label.confidence,

        source:
          label.source,

        created:
          created
      }
    end
  end
end
