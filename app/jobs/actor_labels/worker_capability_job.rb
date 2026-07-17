# frozen_string_literal: true

module ActorLabels
  class WorkerCapabilityJob < ApplicationJob
    queue_as :actor_labels_strict

    def perform
      ActorLabels::StrictBatchJob.publish_worker_status!

      {
        ok: true,
        queue: self.class.queue_name,
        write_enabled:
          ActorLabels::StrictBatchJob.write_enabled?
      }
    end
  end
end
