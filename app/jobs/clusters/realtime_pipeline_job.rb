# frozen_string_literal: true

module Clusters
  class RealtimePipelineJob < ApplicationJob
    queue_as :default

    def perform
      JobRunner.run!(
        "clusters_realtime_pipeline",
        triggered_by: "cron",
        meta: { category: "cluster", source: "cron" }
      ) do |job_run|
        consumed = Clusters::BlockConsumer.call
        batch_result = Clusters::BatchFlusher.call
        flush_result = Clusters::SqlBatchFlusher.call

        JobRunner.progress!(
          job_run,
          pct: 100,
          label: "consumed=#{consumed}, processed=#{batch_result[:processed]}, inserted=#{flush_result[:inserted]}",
          meta: {
            consumed: consumed,
            batch: batch_result,
            flush: flush_result
          }
        )

        {
          consumed: consumed,
          batch: batch_result,
          flush: flush_result
        }
      end

      Turbo::StreamsChannel.broadcast_replace_to(
        "cluster_realtime",
        target: "cluster_realtime_pipeline",
        partial: "system/realtime/cluster_pipeline",
        locals: {
          cluster_realtime: System::ClusterRealtimePipelineStatus.call
        }
      )
    end
  end
end