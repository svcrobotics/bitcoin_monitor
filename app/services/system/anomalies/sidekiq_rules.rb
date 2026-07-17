# frozen_string_literal: true

module System
  module Anomalies
    module SidekiqRules
      module_function

      QUEUE_BACKLOG_WARNING = 100
      RETRY_WARNING = 25
      DEAD_CRITICAL = 1

      def call(context:)
        snapshot =
          context[:sidekiq] || {}

        anomalies = []

        (snapshot[:queue_processes] || {}).each do |queue, count|
          next if count.to_i == 1

          severity =
            count.to_i.zero? ? "critical" : "critical"

          anomalies << Base.anomaly(
            code:
              count.to_i.zero? ?
                "sidekiq_worker_missing" :
                "sidekiq_worker_duplicated",
            module_name: "sidekiq",
            severity: severity,
            title:
              count.to_i.zero? ?
                "Un worker Sidekiq attendu est absent" :
                "Une queue Sidekiq a plusieurs workers",
            facts: {
              queue: queue,
              process_count: count.to_i
            },
            fingerprint: "sidekiq:#{queue}:process_count"
          )
      end

        (snapshot[:queues] || {}).each do |queue, data|
          size =
            data[:size].to_i

          next unless size >= QUEUE_BACKLOG_WARNING

          anomalies << Base.anomaly(
            code: "sidekiq_queue_backlog",
            module_name: "sidekiq",
            severity: "warning",
            title: "Une queue Sidekiq accumule du travail",
            facts: {
              queue: queue,
              queue_size: size,
              latency_seconds: data[:latency].to_f.round(1)
            },
            fingerprint: "sidekiq:#{queue}:backlog",
            confirmation_observations: 2
          )
        end

        retries =
          snapshot[:retries].to_i

        if retries >= RETRY_WARNING
          anomalies << Base.anomaly(
            code: "sidekiq_retries_high",
            module_name: "sidekiq",
            severity: "warning",
            title: "Sidekiq contient beaucoup de retries",
            facts: {
              retries: retries
            },
            fingerprint: "sidekiq:retries_high"
          )
        end

        dead =
          snapshot[:dead].to_i

        if dead >= DEAD_CRITICAL
          anomalies << Base.anomaly(
            code: "sidekiq_dead_jobs_present",
            module_name: "sidekiq",
            severity: "critical",
            title: "Sidekiq contient des jobs morts",
            facts: {
              dead_jobs: dead
            },
            fingerprint: "sidekiq:dead_jobs_present"
          )
        end

        anomalies
      end
    end
  end
end
