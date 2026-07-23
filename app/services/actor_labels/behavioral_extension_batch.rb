# frozen_string_literal: true

module ActorLabels
  class BehavioralExtensionBatch
    DEFAULT_LIMIT = 100
    MAX_LIMIT = 5_000

    def self.call(limit: DEFAULT_LIMIT, after_id: 0, dry_run: true)
      new(limit: limit, after_id: after_id, dry_run: dry_run).call
    end

    def initialize(limit:, after_id:, dry_run:)
      @limit = limit.to_i.clamp(1, MAX_LIMIT)
      @after_id = [after_id.to_i, 0].max
      @dry_run = dry_run == true
    end

    def call
      snapshots = ActorBehaviors::CertifiedScope.call
        .where("actor_behavior_snapshots.id > ?", after_id)
        .order("actor_behavior_snapshots.id ASC")
        .limit(limit)

      results = snapshots.map do |snapshot|
        BehavioralExtensionWriter.call(snapshot: snapshot, dry_run: dry_run, scope_verified: true)
      end

      cursor = {
        after_id: after_id,
        last_id: snapshots.last&.id || after_id,
        has_more: ActorBehaviors::CertifiedScope.call.where("actor_behavior_snapshots.id > ?", snapshots.last&.id || after_id).exists?
      }
      cleanup = reconcile_source(cursor: cursor)

      {
        ok: results.all? { |result| result[:ok] },
        dry_run: dry_run,
        source: BehavioralExtensionRuleSet::SOURCE,
        scanned: results.size,
        results: results,
        cursor: cursor,
        expected_labels: cleanup[:expected_labels],
        obsolete_labels: cleanup[:obsolete_labels],
        expected_upsert_labels: cleanup[:expected_upsert_labels],
        created_or_updated_labels: cleanup[:created_or_updated_labels]
      }
    end

    private

    attr_reader :limit, :after_id, :dry_run

    def reconcile_source(cursor:)
      return { expected_labels: [], obsolete_labels: [] } if cursor[:has_more]

      expected = []
      begin
        ActorBehaviors::CertifiedScope.call.find_each do |snapshot|
          result = BehavioralExtensionRuleSet.call(snapshot: snapshot, scope_verified: true)
          raise "certified scope snapshot became ineligible: #{snapshot.id}" unless result[:eligible]

          result[:labels].each do |label|
            expected << { key: [snapshot.cluster_id, label.fetch(:label), label.fetch(:rule_version)], snapshot: snapshot }
          end
        end
      rescue StandardError
        return { expected_labels: nil, obsolete_labels: nil, expected_upsert_labels: nil, created_or_updated_labels: nil }
      end

      expected = expected.uniq { |entry| entry[:key] }
      current = ActorLabel.where(source: BehavioralExtensionRuleSet::SOURCE).to_a
      obsolete = current.reject do |label|
        expected.any? { |entry| entry[:key] == [label.cluster_id, label.label, label.rule_version] }
      end
      obsolete_names = obsolete.map(&:label)
      upserts = expected.filter_map do |entry|
        result = BehavioralExtensionWriter.call(snapshot: entry[:snapshot], dry_run: true, scope_verified: true)
        result[:expected_upsert_labels]
      end.flatten
      unless dry_run
        ActorLabel.where(id: obsolete.map(&:id)).delete_all if obsolete.any?
        expected.each do |entry|
          BehavioralExtensionWriter.call(snapshot: entry[:snapshot], dry_run: false, scope_verified: true)
        end
      end
      { expected_labels: expected.size, obsolete_labels: obsolete_names, expected_upsert_labels: upserts, created_or_updated_labels: dry_run ? [] : upserts }
    end
  end
end
