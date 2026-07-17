# frozen_string_literal: true

require "json"

module Clusters
  class OperationalSnapshot
    STRICT_QUEUE = "cluster_strict"

    def self.call
      new.call
    end

    def call
      require "sidekiq/api"

      layer1 = Layer1::OperationalSnapshot.call

      layer1_tip = layer1[:processed_height]

      if layer1_tip.nil?
        raise "Layer1 processed height unavailable"
      end

      layer1_tip = layer1_tip.to_i

      latest_processed =
        ClusterProcessedBlock
          .where(status: "processed")
          .order(height: :desc)
          .pick(:height, :updated_at)

      cluster_tip =
        latest_processed ? latest_processed[0].to_i : 0

      last_cluster_processed_at =
        latest_processed ? latest_processed[1] : nil

      cluster_lag =
        [
          layer1_tip - cluster_tip,
          0
        ].max

      processes =
        Sidekiq::ProcessSet.new.select do |process|
          Array(process["queues"]).include?(STRICT_QUEUE)
        end

      queue_size =
        Sidekiq::Queue.new(STRICT_QUEUE).size

      busy_workers =
        processes.sum do |process|
          process["busy"].to_i
        end

      active_jobs =
        strict_active_jobs

      active_worker_count =
        [
          busy_workers,
          active_jobs.size
        ].max

      coverage =
        Clusters::Coverage::
          OperationalSnapshot.read

      issues = []

      issues << "layer1_unavailable" if layer1[:error].present?
      issues << "cluster_strict_worker_missing" if processes.empty?
      issues << "cluster_tip_above_layer1" if cluster_tip > layer1_tip

      status =
        if issues.any?
          "critical"
        elsif cluster_lag > 20 || queue_size > 100
          "warning"
        elsif cluster_lag.positive?
          "syncing"
        else
          "healthy"
        end

      pipeline_state =
        if processes.empty?
          "worker_missing"
        elsif active_worker_count.positive?
          "active"
        elsif queue_size.positive?
          "queued"
        elsif cluster_lag.zero?
          "idle_synced"
        else
          "waiting"
        end

      current_height =
        if active_worker_count.positive? && cluster_lag.positive?
          cluster_tip + 1
        end

      recent_checkpoints =
        ClusterProcessedBlock
          .where(status: "processed")
          .order(height: :desc)
          .limit(5)
          .pluck(:height, :duration_ms, :processed_at)
          .map do |height, duration_ms, processed_at|
            {
              height: height.to_i,
              duration_ms: duration_ms.to_i,
              processed_at: processed_at
            }
          end

      {
        module: "cluster_health",
        source: "cluster_operational_snapshot",
        generated_at: Time.current,
        status: status,

        sync: {
          best_height: layer1_tip,
          layer1_tip: layer1_tip,
          layer1_status: layer1[:status],
          bitcoin_core_height: layer1[:bitcoin_core_height],
          cluster_tip: cluster_tip,
          scanner_cursor: cluster_tip,
          input_lag: cluster_lag,
          spent_lag: cluster_lag,
          scanner_lag: cluster_lag
        },

        activity: {
          pipeline_state: pipeline_state,
          current_height: current_height,
          last_cluster_processed_at: last_cluster_processed_at,
          last_actor_profile_at: nil
        },

        recent_checkpoints: recent_checkpoints,

        coverage: coverage,

        queues: {
          STRICT_QUEUE => queue_size
        },

        automation: {
          queue_name: STRICT_QUEUE,
          process_present: processes.any?,
          process_count: processes.size,
          busy_workers: active_worker_count,
          sidekiq_busy_workers: busy_workers,
          active_jobs: active_jobs.size,
          queue_size: queue_size
        },

        issues: issues
      }
    rescue StandardError => error
      Rails.logger.error(
        "[cluster_operational_snapshot] " \
        "#{error.class}: #{error.message}"
      )

      {
        module: "cluster_health",
        source: "cluster_operational_snapshot",
        generated_at: Time.current,
        status: "critical",

        sync: {
          best_height: nil,
          layer1_tip: nil,
          cluster_tip: nil,
          scanner_cursor: nil,
          input_lag: 999_999,
          spent_lag: 999_999,
          scanner_lag: 999_999
        },

        activity: {
          pipeline_state: "unknown",
          last_cluster_processed_at: nil,
          last_actor_profile_at: nil
        },

        coverage: {
          status: "unknown",
          complete: false,
          missing_addresses: nil,
          unclustered_addresses: nil,
          invalid_cluster_refs: nil,
          address_cursor_lag: nil,
          checked_at: nil
        },

        queues: {
          STRICT_QUEUE => 0
        },

        issues: ["snapshot_error"],
        error: "#{error.class}: #{error.message}"
      }
    end

    def strict_active_jobs
      Sidekiq::WorkSet.new.filter_map do |_process_id, _thread_id, work|
        payload =
          sidekiq_work_payload(work)

        next unless payload["queue"].to_s == STRICT_QUEUE
        next unless sidekiq_payload_job_class(payload).to_s == "Clusters::StrictTipSyncJob"

        {
          queue: payload["queue"],
          job_class: sidekiq_payload_job_class(payload)
        }
      end
    rescue StandardError
      []
    end

    def sidekiq_work_payload(work)
      raw =
        if work.respond_to?(:payload)
          work.payload
        else
          work.instance_variable_get(:@hsh)
        end

      case raw
      when Hash
        raw
      when String
        JSON.parse(raw)
      else
        {}
      end
    end

    def sidekiq_payload_job_class(payload)
      first_arg =
        Array(payload["args"]).first

      if first_arg.is_a?(Hash)
        first_arg["job_class"] ||
          first_arg["wrapped"] ||
          payload["class"]
      else
        payload["class"]
      end
    end
  end
end
