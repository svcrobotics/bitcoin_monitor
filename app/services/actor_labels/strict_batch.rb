# frozen_string_literal: true

module ActorLabels
  class StrictBatch
    DEFAULT_LIMIT = 500
    MAX_LIMIT = 20_000

    RULE_SET = ActorLabels::StrictRuleSetV2

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
        dry_run
    end

    def call
      started_at =
        Process.clock_gettime(
          Process::CLOCK_MONOTONIC
        )

      tip = cluster_tip

      raise "Cluster strict tip missing" if tip.zero?

      counters =
        Hash.new(0)

      rejection_reasons =
        Hash.new(0)

      errors = []

      profiles =
        profiles_scope.to_a

      profiles.each do |profile|
        counters[:scanned] += 1

        begin
          result =
            ActorLabels::StrictWriter.call(
              profile: profile,
              cluster_tip: tip,
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
            counters[:profiles_with_labels] += 1
            counters[:expected_labels] +=
              expected_labels.size
          else
            counters[:profiles_without_labels] += 1
          end

          counters[:written_labels] +=
            written_labels.size

          counters[:deleted_labels] +=
            deleted_labels.size
        rescue StandardError => error
          counters[:failed] += 1

          if errors.size < 20
            errors << {
              actor_profile_id:
                profile.id,

              cluster_id:
                profile.cluster_id,

              error_class:
                error.class.name,

              message:
                error.message
            }
          end
        end
      end

      last_id =
        profiles.last&.id ||
        after_id

      has_more =
        certified_scope
          .where(
            "actor_profiles.id > ?",
            last_id
          )
          .exists?

      {
        ok:
          counters[:failed].zero?,

        dry_run:
          dry_run,

        source:
          RULE_SET::SOURCE,

        rule_version:
          RULE_SET::RULE_VERSION,

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
          cluster_tip:
            tip,

          profile_height_min:
            profiles
              .map(&:last_computed_height)
              .compact
              .min,

          profile_height_max:
            profiles
              .map(&:last_computed_height)
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

          profiles_with_labels:
            counters[:profiles_with_labels],

          profiles_without_labels:
            counters[:profiles_without_labels],

          expected_labels:
            counters[:expected_labels],

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
          actor_labels:
            ActorLabel.count,

          strict_actor_labels:
            ActorLabel.where(
              source: RULE_SET::SOURCE
            ).count
        },

        errors:
          errors,

        runtime_ms:
          elapsed_ms(started_at)
      }
    end

    private

    attr_reader :limit, :after_id, :dry_run

    def certified_scope
      ActorProfiles::CertifiedScope.call
    end

    def profiles_scope
      certified_scope
        .includes(:cluster)
        .where(
          "actor_profiles.id > ?",
          after_id
        )
        .order(
          "actor_profiles.id ASC"
        )
        .limit(limit)
    end

    def cluster_tip
      ClusterProcessedBlock
        .where(status: "processed")
        .maximum(:height)
        .to_i
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
