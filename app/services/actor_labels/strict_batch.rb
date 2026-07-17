# frozen_string_literal: true

module ActorLabels
  class StrictBatch
    DEFAULT_LIMIT = 100
    MAX_LIMIT = 5_000

    RULE_SET =
      ActorLabels::StrictRuleSet

    WRITER =
      ActorLabels::StrictWriter

    def self.call(
      limit: DEFAULT_LIMIT,
      after_id: 0,
      dry_run: true
    )
      new(
        limit: limit,
        after_id: after_id,
        dry_run: dry_run
      ).call
    end

    def initialize(limit:, after_id:, dry_run:)
      @limit =
        [
          [limit.to_i, 1].max,
          MAX_LIMIT
        ].min

      @after_id =
        [after_id.to_i, 0].max

      @dry_run =
        dry_run == true
    end

    def call
      started_at =
        Process.clock_gettime(
          Process::CLOCK_MONOTONIC
        )

      counters =
        Hash.new(0)

      rejection_reasons =
        Hash.new(0)

      errors = []

      snapshots =
        snapshots_scope.to_a

      snapshots.each do |snapshot|
        counters[:scanned] += 1

        begin
          result =
            WRITER.call(
              snapshot: snapshot,
              dry_run: dry_run
            )

          if result[:eligible]
            counters[:eligible] += 1
          else
            counters[:ineligible] += 1

            rejection_reasons[
              result[:reason]
            ] += 1
          end

          expected_labels =
            Array(
              result[:expected_labels]
            )

          written_labels =
            Array(
              result[:written_labels]
            )

          deleted_labels =
            Array(
              result[:deleted_labels]
            )

          if expected_labels.any?
            counters[:snapshots_with_labels] += 1

            counters[:expected_labels] +=
              expected_labels.size

            expected_labels.each do |label|
              counters[
                :"expected_#{label}"
              ] += 1
            end
          else
            counters[:snapshots_without_labels] += 1
          end

          counters[:written_labels] +=
            written_labels.size

          counters[:deleted_labels] +=
            deleted_labels.size
        rescue StandardError => error
          counters[:failed] += 1

          if errors.size < 20
            errors << {
              actor_behavior_snapshot_id:
                snapshot.id,

              actor_profile_id:
                snapshot.actor_profile_id,

              cluster_id:
                snapshot.cluster_id,

              error_class:
                error.class.name,

              message:
                error.message
            }
          end
        end
      end

      last_id =
        snapshots.last&.id ||
        after_id

      has_more =
        certified_scope
          .where(
            "actor_behavior_snapshots.id > ?",
            last_id
          )
          .exists?

      reconciliation =
        reconcile_obsolete_labels(
          cycle_completed: !has_more
        )

      {
        ok:
          counters[:failed].zero?,

        dry_run:
          dry_run,

        source:
          RULE_SET::SOURCE,

        rule_version:
          RULE_SET::RULE_VERSION,

        behavior_version:
          RULE_SET::BEHAVIOR_VERSION,

        cursor: {
          after_id:
            after_id,

          last_id:
            last_id,

          has_more:
            has_more,

          next_after_id:
            has_more ? last_id : 0
        },

        heights: {
          profile_height_min:
            snapshots
              .map(&:profile_height)
              .compact
              .min,

          profile_height_max:
            snapshots
              .map(&:profile_height)
              .compact
              .max
        },

        batch: {
          limit:
            limit,

          scanned:
            counters[:scanned],

          eligible:
            counters[:eligible],

          ineligible:
            counters[:ineligible],

          snapshots_with_labels:
            counters[:snapshots_with_labels],

          snapshots_without_labels:
            counters[:snapshots_without_labels],

          expected_labels:
            counters[:expected_labels],

          expected_by_label:
            expected_by_label(counters),

          written_labels:
            counters[:written_labels],

          deleted_labels:
            counters[:deleted_labels],

          failed:
            counters[:failed]
        },

        rejected_by_reason:
          rejection_reasons.sort.to_h,

        database: {
          strict_actor_labels:
            ActorLabel.where(
              source: RULE_SET::SOURCE
            ).count
        },

        reconciliation:
          reconciliation,

        errors:
          errors,

        runtime_ms:
          elapsed_ms(started_at)
      }
    end

    private

    attr_reader :limit, :after_id, :dry_run

    def certified_scope
      ActorBehaviors::CertifiedScope.call
    end

    def snapshots_scope
      certified_scope
        .where(
          "actor_behavior_snapshots.id > ?",
          after_id
        )
        .order(
          "actor_behavior_snapshots.id ASC"
        )
        .limit(limit)
    end

    def expected_by_label(counters)
      ActorLabel::LABELS.to_h do |label|
        [
          label,
          counters[
            :"expected_#{label}"
          ].to_i
        ]
      end
    end

    def reconcile_obsolete_labels(cycle_completed:)
      unless cycle_completed
        return {
          performed: false,
          reason: "cycle_not_completed",
          expected_deletions: 0,
          deleted: 0
        }
      end

      obsolete_scope =
        ActorLabel
          .where(source: RULE_SET::SOURCE)
          .where.not(
            cluster_id:
              certified_scope.select(:cluster_id)
          )

      expected_deletions =
        obsolete_scope.count

      deleted =
        if dry_run
          0
        else
          obsolete_scope.delete_all
        end

      {
        performed: true,
        dry_run: dry_run,
        expected_deletions:
          expected_deletions,
        deleted:
          deleted
      }
    end

    def elapsed_ms(started_at)
      (
        (
          Process.clock_gettime(
            Process::CLOCK_MONOTONIC
          ) -
          started_at
        ) * 1_000
      ).round
    end
  end
end
