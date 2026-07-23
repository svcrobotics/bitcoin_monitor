# frozen_string_literal: true

module ActorLabels
  class BehavioralExtensionWriter
    RULE_SET = ActorLabels::BehavioralExtensionRuleSet
    SOURCE = RULE_SET::SOURCE

    def self.call(snapshot:, dry_run: true, scope_verified: false)
      new(snapshot: snapshot, dry_run: dry_run, scope_verified: scope_verified).call
    end

    def initialize(snapshot:, dry_run:, scope_verified: false)
      @snapshot = snapshot
      @dry_run = dry_run == true
      @scope_verified = scope_verified == true
    end

    def call
      result = RULE_SET.call(snapshot: snapshot, scope_verified: scope_verified)
      return ineligible_result(result) unless result[:eligible]

      expected_labels = Array(result[:labels])
      expected_names = expected_labels.map { |label| label.fetch(:label) }
      existing_scope = ActorLabel.where(cluster_id: snapshot.cluster_id, source: SOURCE)
      existing_by_label = existing_scope.index_by(&:label)
      expected_upsert_labels = expected_labels.select do |label_data|
        !current_label?(existing_by_label[label_data.fetch(:label)], label_data)
      end
      obsolete_scope = expected_names.empty? ? existing_scope : existing_scope.where.not(label: expected_names)
      expected_deleted_labels = obsolete_scope.pluck(:label)
      written_labels = []
      deleted_labels = []

      unless dry_run
        ActorLabel.transaction do
          deleted_labels = expected_deleted_labels
          obsolete_scope.delete_all
          written_labels = expected_upsert_labels.map { |label_data| write_label(label_data: label_data, rule_result: result) }
        end
      end

      {
        ok: true,
        dry_run: dry_run,
        eligible: true,
        reason: nil,
        actor_behavior_snapshot_id: snapshot.id,
        actor_profile_id: snapshot.actor_profile_id,
        cluster_id: snapshot.cluster_id,
        expected_labels: expected_names,
        expected_upsert_labels: expected_upsert_labels.map { |label| label.fetch(:label) },
        expected_deleted_labels: expected_deleted_labels,
        written_labels: written_labels,
        deleted_labels: deleted_labels
      }
    rescue StandardError => error
      {
        ok: false,
        dry_run: dry_run,
        eligible: false,
        reason: :write_failed,
        actor_behavior_snapshot_id: snapshot&.id,
        cluster_id: snapshot&.cluster_id,
        error_class: error.class.name,
        error_message: error.message,
        expected_labels: [],
        expected_deleted_labels: [],
        written_labels: [],
        deleted_labels: []
      }
    end

    private

    attr_reader :snapshot, :dry_run, :scope_verified

    def ineligible_result(result)
      {
        ok: true,
        dry_run: dry_run,
        eligible: false,
        reason: result[:reason],
        actor_behavior_snapshot_id: snapshot&.id,
        cluster_id: snapshot&.cluster_id,
        expected_labels: [],
        expected_upsert_labels: [],
        expected_deleted_labels: [],
        written_labels: [],
        deleted_labels: []
      }
    end

    def current_label?(label, label_data)
      return false unless label

      label.actor_profile_id == snapshot.actor_profile_id &&
        label.actor_behavior_snapshot_id == snapshot.id &&
        label.rule_version.to_s == label_data.fetch(:rule_version).to_s &&
        label.certified_at == snapshot.certified_at &&
        label.confidence.to_i == label_data.fetch(:confidence).to_i
    end

    def write_label(label_data:, rule_result:)
      label = ActorLabel.find_or_initialize_by(
        cluster_id: snapshot.cluster_id,
        label: label_data.fetch(:label),
        source: SOURCE
      )
      created = label.new_record?
      now = Time.current
      label.first_seen_at ||= now
      label.assign_attributes(
        actor_profile_id: snapshot.actor_profile_id,
        actor_behavior_snapshot_id: snapshot.id,
        rule_version: label_data.fetch(:rule_version),
        certified_at: snapshot.certified_at,
        confidence: label_data.fetch(:confidence),
        metadata: {
          strict: true,
          behavior_based: true,
          shadow: true,
          actor_behavior_snapshot_id: snapshot.id,
          actor_profile_id: snapshot.actor_profile_id,
          cluster_id: snapshot.cluster_id,
          rule_version: label_data.fetch(:rule_version),
          reason: label_data.fetch(:reason),
          evidence: rule_result.fetch(:evidence)
        },
        last_seen_at: now
      )
      label.save!
      { id: label.id, label: label.label, confidence: label.confidence, source: label.source, created: created }
    end
  end
end
