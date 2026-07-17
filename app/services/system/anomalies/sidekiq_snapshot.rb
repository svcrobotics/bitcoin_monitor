# frozen_string_literal: true

require "sidekiq/api"

module System
  module Anomalies
    module SidekiqSnapshot
      EXPECTED_QUEUES = %w[
        scheduler
        layer1_strict
        cluster_strict
        actor_profile_strict
        actor_behavior_strict
        actor_labels_strict
        layer1_audit
        tx_outputs_async
        tx_output_projection
        cluster_coverage
      ].freeze

      module_function

      def call
        processes =
          Sidekiq::ProcessSet.new.to_a

        queue_processes =
          EXPECTED_QUEUES.index_with do |queue|
            processes.count do |process|
              Array(process["queues"]).include?(queue) &&
                process["quiet"].to_s != "true"
            end
          end

        queues =
          EXPECTED_QUEUES.index_with do |queue|
            q = Sidekiq::Queue.new(queue)

            {
              size: q.size,
              latency: q.latency
            }
          end

        {
          queue_processes: queue_processes,
          queues: queues,
          retries: Sidekiq::RetrySet.new.size,
          dead: Sidekiq::DeadSet.new.size
        }
      end
    end
  end
end
