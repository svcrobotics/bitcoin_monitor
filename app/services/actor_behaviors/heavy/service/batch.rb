# frozen_string_literal: true

module ActorBehaviors
  module Heavy
    module Service
      class Batch
        VERSION =
          "actor_behavior_heavy_service_batch_v1"

        # Lock distinct du batch Heavy Exchange (42_022).
        ADVISORY_LOCK_KEY =
          42_023

        DEFAULT_LIMIT = 1
        MAX_LIMIT = 5

        def self.call(
          limit: DEFAULT_LIMIT,
          trigger: "manual",
          distribution_window_blocks:
            Build::
              DEFAULT_DISTRIBUTION_WINDOW_BLOCKS,
          distribution_chunk_size: nil,
          minimum_height_delta:
            CandidateScope::
              DEFAULT_MINIMUM_HEIGHT_DELTA,
          to_height: nil,
          candidate_scope: CandidateScope,
          builder: Build,
          connection: nil
        )
          new(
            limit:
              limit,

            trigger:
              trigger,

            distribution_window_blocks:
              distribution_window_blocks,

            distribution_chunk_size:
              distribution_chunk_size,

            minimum_height_delta:
              minimum_height_delta,

            to_height:
              to_height,

            candidate_scope:
              candidate_scope,

            builder:
              builder,

            connection:
              connection
          ).call
        end

        def initialize(
          limit:,
          trigger:,
          distribution_window_blocks:,
          distribution_chunk_size:,
          minimum_height_delta:,
          to_height:,
          candidate_scope:,
          builder:,
          connection:
        )
          @limit =
            limit.to_i.clamp(
              1,
              MAX_LIMIT
            )

          @trigger =
            trigger.to_s.presence ||
            "unknown"

          @distribution_window_blocks =
            [
              distribution_window_blocks.to_i,
              1
            ].max

          @distribution_chunk_size =
            distribution_chunk_size

          @minimum_height_delta =
            [
              minimum_height_delta.to_i,
              1
            ].max

          @requested_to_height =
            to_height&.to_i

          @candidate_scope =
            candidate_scope

          @builder =
            builder

          @provided_connection =
            connection

          @lock_acquired =
            false
        end

        def call
          started_at =
            Process.clock_gettime(
              Process::CLOCK_MONOTONIC
            )

          unless acquire_lock
            return deferred_batch(
              reason:
                :heavy_service_batch_locked
            )
          end

          to_height =
            resolve_to_height

          if to_height <= 0
            return deferred_batch(
              reason:
                :processed_height_missing
            )
          end

          candidates =
            candidate_scope.call(
              limit:
                limit,

              to_height:
                to_height,

              minimum_height_delta:
                minimum_height_delta
            )

          results =
            candidates.map do |snapshot|
              process_candidate(
                snapshot:
                  snapshot,

                to_height:
                  to_height
              )
            end

          duration =
            Process.clock_gettime(
              Process::CLOCK_MONOTONIC
            ) -
            started_at

          {
            ok:
              results.none? do |result|
                result[:ok] == false
              end,

            status:
              batch_status(
                results
              ),

            batch_version:
              VERSION,

            analysis_kind:
              Contract::ANALYSIS_KIND,

            shadow_mode:
              Contract::SHADOW_MODE,

            trigger:
              trigger,

            labels_enabled:
              false,

            to_height:
              to_height,

            requested_limit:
              limit,

            selected:
              candidates.length,

            certified:
              count_status(
                results,
                "certified"
              ),

            deferred:
              count_status(
                results,
                "deferred"
              ),

            failed:
              results.count do |result|
                result[:status] ==
                  "failed" ||
                  result[:ok] == false
              end,

            created:
              count_flag(
                results,
                :created
              ),

            updated:
              count_flag(
                results,
                :updated
              ),

            unchanged:
              count_flag(
                results,
                :unchanged
              ),

            labels_synchronized:
              0,

            label_sync_failed:
              0,

            label_sync_skipped:
              results.count do |result|
                result.dig(
                  :label_sync,
                  :status
                ) ==
                  "skipped"
              end,

            duration_seconds:
              duration.round(3),

            results:
              results
          }
        rescue StandardError => error
          {
            ok: false,
            status: "failed",
            reason:
              :batch_failed,

            batch_version:
              VERSION,

            analysis_kind:
              Contract::ANALYSIS_KIND,

            shadow_mode:
              Contract::SHADOW_MODE,

            trigger:
              trigger,

            labels_enabled:
              false,

            error_class:
              error.class.name,

            error_message:
              error.message,

            results: []
          }
        ensure
          release_lock
        end

        private

        attr_reader(
          :limit,
          :trigger,
          :distribution_window_blocks,
          :distribution_chunk_size,
          :minimum_height_delta,
          :requested_to_height,
          :candidate_scope,
          :builder,
          :provided_connection
        )

        def connection
          provided_connection ||
            ActiveRecord::Base.connection
        end

        def resolve_to_height
          requested_to_height ||
            BlockBufferModel
              .where(
                status:
                  "processed"
              )
              .maximum(
                :height
              )
              .to_i
        end

        def acquire_lock
          @lock_acquired =
            ActiveModel::Type::Boolean
              .new
              .cast(
                connection.select_value(
                  "SELECT " \
                    "pg_try_advisory_lock(" \
                    "#{ADVISORY_LOCK_KEY}" \
                    ")"
                )
              )
        end

        def release_lock
          return unless @lock_acquired

          connection.select_value(
            "SELECT " \
              "pg_advisory_unlock(" \
              "#{ADVISORY_LOCK_KEY}" \
              ")"
          )

          @lock_acquired =
            false
        rescue StandardError => error
          Rails.logger.warn(
            "[ActorBehaviors::Heavy::Service::Batch] " \
            "advisory_unlock_failed " \
            "error=#{error.class}: " \
            "#{error.message}"
          )
        end

        def process_candidate(
          snapshot:,
          to_height:
        )
          result =
            builder.call(
              source_cluster_id:
                snapshot.cluster_id,

              distribution_window_blocks:
                distribution_window_blocks,

              distribution_chunk_size:
                distribution_chunk_size,

              to_height:
                to_height
            )

          result.merge(
            actor_behavior_snapshot_id:
              snapshot.id,

            analysis_kind:
              Contract::ANALYSIS_KIND,

            label_sync: {
              status: "skipped",
              reason: :shadow_mode
            }
          )
        rescue StandardError => error
          {
            ok: false,
            status: "failed",
            reason:
              :candidate_processing_failed,

            source_cluster_id:
              snapshot.cluster_id,

            actor_behavior_snapshot_id:
              snapshot.id,

            analysis_kind:
              Contract::ANALYSIS_KIND,

            error_class:
              error.class.name,

            error_message:
              error.message,

            label_sync: {
              status: "skipped",
              reason: :shadow_mode
            }
          }
        end

        def deferred_batch(reason:)
          {
            ok: true,
            status: "deferred",
            reason:
              reason,

            batch_version:
              VERSION,

            analysis_kind:
              Contract::ANALYSIS_KIND,

            shadow_mode:
              Contract::SHADOW_MODE,

            trigger:
              trigger,

            labels_enabled:
              false,

            selected:
              0,

            certified:
              0,

            deferred:
              0,

            failed:
              0,

            created:
              0,

            updated:
              0,

            unchanged:
              0,

            labels_synchronized:
              0,

            label_sync_failed:
              0,

            label_sync_skipped:
              0,

            results: []
          }
        end

        def count_status(
          results,
          status
        )
          results.count do |result|
            result[:status] ==
              status
          end
        end

        def count_flag(
          results,
          flag
        )
          results.count do |result|
            result[flag] ==
              true
          end
        end

        def batch_status(results)
          return "idle" if
            results.empty?

          return "failed" if
            results.any? do |result|
              result[:ok] == false ||
                result[:status] ==
                  "failed"
            end

          return "deferred" if
            results.all? do |result|
              result[:status] ==
                "deferred"
            end

          "completed"
        end
      end
    end
  end
end
