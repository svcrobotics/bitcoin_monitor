# frozen_string_literal: true

module ActorBehaviors
  class HeavyBatchJob <
    ApplicationJob

    queue_as :actor_behavior_heavy

    def perform(
      limit: 1,
      trigger: "manual",
      sweep_window_blocks:
        ActorBehaviors::Heavy::Build::
          DEFAULT_SWEEP_WINDOW_BLOCKS,
      distribution_window_blocks:
        ActorBehaviors::Heavy::Build::
          DEFAULT_DISTRIBUTION_WINDOW_BLOCKS,
      minimum_height_delta:
        ActorBehaviors::Heavy::CandidateScope::
          DEFAULT_MINIMUM_HEIGHT_DELTA,
      to_height: nil
    )
      result =
        ActorBehaviors::Heavy::Batch.call(
          limit: limit,
          trigger: trigger,
          sweep_window_blocks:
            sweep_window_blocks,
          distribution_window_blocks:
            distribution_window_blocks,
          minimum_height_delta:
            minimum_height_delta,
          to_height: to_height
        )

      Rails.logger.info(
        "[ActorBehaviors::HeavyBatchJob] " \
        "status=#{result[:status]} " \
        "selected=#{result[:selected]} " \
        "certified=#{result[:certified]} " \
        "deferred=#{result[:deferred]} " \
        "failed=#{result[:failed]} " \
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
