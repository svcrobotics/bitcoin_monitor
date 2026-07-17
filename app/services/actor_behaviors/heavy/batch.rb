# frozen_string_literal: true

module ActorBehaviors
  module Heavy
    class Batch
      VERSION =
        "actor_behavior_heavy_batch_v1"

      ADVISORY_LOCK_KEY =
        42_022

      DEFAULT_LIMIT = 1
      MAX_LIMIT = 5

      def self.call(
        limit: DEFAULT_LIMIT,
        trigger: "manual",
        sweep_window_blocks:
          Build::DEFAULT_SWEEP_WINDOW_BLOCKS,
        distribution_window_blocks:
          Build::
            DEFAULT_DISTRIBUTION_WINDOW_BLOCKS,
        minimum_height_delta:
          CandidateScope::
            DEFAULT_MINIMUM_HEIGHT_DELTA,
        to_height: nil
      )
        new(
          limit: limit,
          trigger: trigger,
          sweep_window_blocks:
            sweep_window_blocks,
          distribution_window_blocks:
            distribution_window_blocks,
          minimum_height_delta:
            minimum_height_delta,
          to_height: to_height
        ).call
      end

      def initialize(
        limit:,
        trigger:,
        sweep_window_blocks:,
        distribution_window_blocks:,
        minimum_height_delta:,
        to_height:
      )
        @limit =
          limit.to_i.clamp(
            1,
            MAX_LIMIT
          )

        @trigger =
          trigger.to_s.presence ||
          "unknown"

        @sweep_window_blocks =
          [
            sweep_window_blocks.to_i,
            1
          ].max

        @distribution_window_blocks =
          [
            distribution_window_blocks.to_i,
            1
          ].max

        @minimum_height_delta =
          [
            minimum_height_delta.to_i,
            1
          ].max

        @requested_to_height =
          to_height&.to_i

        @lock_acquired = false
      end

      def call
        started_at =
          Process.clock_gettime(
            Process::CLOCK_MONOTONIC
          )

        unless acquire_lock
          return {
            ok: true,
            status: "deferred",
            reason: :heavy_batch_locked,
            batch_version: VERSION,
            trigger: trigger,
            selected: 0,
            results: []
          }
        end

        to_height =
          resolve_to_height

        if to_height <= 0
          return {
            ok: true,
            status: "deferred",
            reason: :processed_height_missing,
            batch_version: VERSION,
            trigger: trigger,
            selected: 0,
            results: []
          }
        end

        candidates =
          CandidateScope.call(
            limit: limit,
            to_height: to_height,
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
          ) - started_at

        {
          ok:
            results.none? do |result|
              result[:ok] == false
            end,

          status:
            batch_status(results),

          batch_version:
            VERSION,

          trigger:
            trigger,

          labels_enabled:
            labels_enabled?,

          to_height:
            to_height,

          requested_limit:
            limit,

          selected:
            candidates.length,

          certified:
            results.count do |result|
              result[:status] ==
                "certified"
            end,

          deferred:
            results.count do |result|
              result[:status] ==
                "deferred"
            end,

          failed:
            results.count do |result|
              result[:status] ==
                "failed" ||
                result[:ok] == false
            end,

          created:
            results.count do |result|
              result[:created] == true
            end,

          updated:
            results.count do |result|
              result[:updated] == true
            end,

          unchanged:
            results.count do |result|
              result[:unchanged] == true
            end,

          labels_synchronized:
            results.count do |result|
              result.dig(
                :label_sync,
                :status
              ) == "synchronized"
            end,

          label_sync_failed:
            results.count do |result|
              result.dig(
                :label_sync,
                :status
              ) == "failed"
            end,

          label_sync_skipped:
            results.count do |result|
              result.dig(
                :label_sync,
                :status
              ) == "skipped"
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
          reason: :batch_failed,
          batch_version: VERSION,
          trigger: trigger,
          error_class: error.class.name,
          error_message: error.message,
          results: []
        }
      ensure
        release_lock
      end

      private

      attr_reader(
        :limit,
        :trigger,
        :sweep_window_blocks,
        :distribution_window_blocks,
        :minimum_height_delta,
        :requested_to_height
      )

      def connection
        ActiveRecord::Base.connection
      end

      def resolve_to_height
        requested_to_height ||
          BlockBufferModel
            .where(status: "processed")
            .maximum(:height)
            .to_i
      end

      def acquire_lock
        @lock_acquired =
          ActiveRecord::Type::Boolean
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

        @lock_acquired = false
      rescue StandardError => error
        Rails.logger.warn(
          "[ActorBehaviors::Heavy::Batch] " \
          "advisory_unlock_failed " \
          "error=#{error.class}: " \
          "#{error.message}"
        )
      end

      def process_candidate(
        snapshot:,
        to_height:
      )
        build_result =
          Build.call(
            source_cluster_id:
              snapshot.cluster_id,

            sweep_window_blocks:
              sweep_window_blocks,

            distribution_window_blocks:
              distribution_window_blocks,

            to_height:
              to_height
          ).merge(
            actor_behavior_snapshot_id:
              snapshot.id
          )

        unless build_result[:status] ==
               "certified" &&
               build_result[:snapshot_id].present?
          return build_result.merge(
            label_sync: {
              status: "skipped",
              reason: :heavy_not_certified
            }
          )
        end

        unless labels_enabled?
          return build_result.merge(
            label_sync: {
              status: "skipped",
              reason: :labels_disabled
            }
          )
        end

        heavy_snapshot =
          ActorBehaviorHeavySnapshot.find_by(
            id:
              build_result[:snapshot_id]
          )

        unless heavy_snapshot
          return build_result.merge(
            ok: false,

            label_sync: {
              status: "failed",
              reason: :heavy_snapshot_missing,
              snapshot_id:
                build_result[:snapshot_id]
            }
          )
        end

        writer_result =
          ActorLabels::HeavyWriter.call(
            snapshot:
              heavy_snapshot,

            dry_run:
              false
          )

        if writer_result[:ok]
          build_result.merge(
            label_sync: {
              status: "synchronized",

              written_labels:
                writer_result[
                  :written_labels
                ],

              deleted_labels:
                writer_result[
                  :deleted_labels
                ]
            }
          )
        else
          build_result.merge(
            ok: false,

            label_sync: {
              status: "failed",
              reason:
                writer_result[:reason],

              error_class:
                writer_result[
                  :error_class
                ],

              error_message:
                writer_result[
                  :error_message
                ],

              validation_errors:
                writer_result[
                  :validation_errors
                ]
            }
          )
        end
      rescue StandardError => error
        {
          ok: false,
          status: "failed",
          reason: :candidate_processing_failed,

          source_cluster_id:
            snapshot.cluster_id,

          actor_behavior_snapshot_id:
            snapshot.id,

          error_class:
            error.class.name,

          error_message:
            error.message,

          label_sync: {
            status: "failed",
            reason:
              :candidate_processing_failed
          }
        }
      end

      def labels_enabled?
        return @labels_enabled if
          defined?(
            @labels_enabled
          )

        @labels_enabled =
          ActiveModel::Type::Boolean
            .new
            .cast(
              ENV.fetch(
                "ACTOR_BEHAVIOR_HEAVY_LABELS_ENABLED",
                "false"
              )
            )
      end

      def batch_status(results)
        return "idle" if results.empty?

        return "failed" if results.any? do |result|
          result[:ok] == false ||
            result[:status] == "failed"
        end

        return "deferred" if results.all? do |result|
          result[:status] ==
            "deferred"
        end

        "completed"
      end
    end
  end
end
