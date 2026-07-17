# frozen_string_literal: true

module ActorBehaviors
  module Heavy
    class ServiceBatchJob <
      ApplicationJob

      queue_as :actor_behavior_heavy

      def perform(
        limit:
          Service::Batch::DEFAULT_LIMIT,
        trigger:
          "manual",
        distribution_window_blocks:
          Service::Build::
            DEFAULT_DISTRIBUTION_WINDOW_BLOCKS,
        distribution_chunk_size:
          nil,
        minimum_height_delta:
          Service::CandidateScope::
            DEFAULT_MINIMUM_HEIGHT_DELTA,
        to_height:
          nil
      )
        result =
          Service::Batch.call(
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
              to_height
          )

        Rails.logger.info(
          "[ActorBehaviors::Heavy::ServiceBatchJob] " \
          "status=#{result[:status]} " \
          "analysis_kind=#{result[:analysis_kind]} " \
          "shadow_mode=#{result[:shadow_mode]} " \
          "selected=#{result[:selected]} " \
          "certified=#{result[:certified]} " \
          "deferred=#{result[:deferred]} " \
          "failed=#{result[:failed]} " \
          "created=#{result[:created]} " \
          "updated=#{result[:updated]} " \
          "unchanged=#{result[:unchanged]} " \
          "labels_synchronized=" \
          "#{result[:labels_synchronized]} " \
          "label_sync_failed=" \
          "#{result[:label_sync_failed]} " \
          "label_sync_skipped=" \
          "#{result[:label_sync_skipped]} " \
          "duration_seconds=" \
          "#{result[:duration_seconds]}"
        )

        result
      end
    end
  end
end
