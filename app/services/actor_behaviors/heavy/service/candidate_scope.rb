# frozen_string_literal: true

module ActorBehaviors
  module Heavy
    module Service
      class CandidateScope
        VERSION =
          Contract::SCOPE_VERSION

        HYPOTHESIS =
          Contract::ANALYSIS_KIND

        DEFAULT_LIMIT = 1
        MAX_LIMIT = 5

        DEFAULT_MINIMUM_HEIGHT_DELTA =
          500

        def self.call(
          limit: DEFAULT_LIMIT,
          to_height:,
          minimum_height_delta:
            DEFAULT_MINIMUM_HEIGHT_DELTA
        )
          new(
            limit: limit,
            to_height: to_height,
            minimum_height_delta:
              minimum_height_delta
          ).call
        end

        def initialize(
          limit:,
          to_height:,
          minimum_height_delta:
        )
          @limit =
            limit.to_i.clamp(
              1,
              MAX_LIMIT
            )

          @to_height =
            to_height.to_i

          @minimum_height_delta =
            [
              minimum_height_delta.to_i,
              1
            ].max
        end

        def call
          ids =
            connection
              .select_values(sql)
              .map(&:to_i)

          records_by_id =
            ActorBehaviorSnapshot
              .includes(:actor_profile)
              .where(id: ids)
              .index_by(&:id)

          ids.filter_map do |id|
            records_by_id[id]
          end
        end

        private

        attr_reader(
          :limit,
          :to_height,
          :minimum_height_delta
        )

        def connection
          ActiveRecord::Base.connection
        end

        def stale_before_height
          [
            to_height -
              minimum_height_delta,
            0
          ].max
        end

        def sql
          ActiveRecord::Base.send(
            :sanitize_sql_array,
            [
              <<~SQL,
                SELECT
                  strict_snapshot.id

                FROM actor_behavior_snapshots
                  strict_snapshot

                INNER JOIN actor_profiles profile
                  ON profile.id =
                     strict_snapshot.actor_profile_id

                LEFT JOIN
                  actor_behavior_heavy_snapshots
                  heavy_snapshot

                  ON heavy_snapshot.cluster_id =
                     strict_snapshot.cluster_id

                  AND heavy_snapshot.analysis_kind =
                      :analysis_kind

                WHERE strict_snapshot.status =
                      'certified'

                  AND strict_snapshot.behavior_version =
                      :strict_behavior_version

                  AND strict_snapshot.signals ->>
                        'service_like_candidate_inputs' =
                      'true'

                  AND (
                    heavy_snapshot.id IS NULL

                    OR heavy_snapshot.status <>
                       'certified'

                    OR heavy_snapshot.heavy_version <>
                       :heavy_version

                    OR
                      heavy_snapshot
                        .source_profile_fingerprint <>
                      strict_snapshot
                        .profile_fingerprint

                    OR heavy_snapshot.window_to_height <
                       :stale_before_height
                  )

                ORDER BY
                  (
                    heavy_snapshot.id IS NULL
                  ) DESC,

                  COALESCE(
                    (
                      strict_snapshot.scores ->>
                        'service_score'
                    )::integer,
                    0
                  ) DESC,

                  strict_snapshot.profile_height DESC,
                  strict_snapshot.cluster_id ASC

                LIMIT :limit
              SQL
              {
                analysis_kind:
                  Contract::ANALYSIS_KIND,

                strict_behavior_version:
                  ActorBehaviors::
                    StrictBuildFromProfile::
                    BEHAVIOR_VERSION,

                heavy_version:
                  Contract::HEAVY_VERSION,

                stale_before_height:
                  stale_before_height,

                limit:
                  limit
              }
            ]
          )
        end
      end
    end
  end
end
