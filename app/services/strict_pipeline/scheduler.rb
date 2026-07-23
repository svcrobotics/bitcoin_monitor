# frozen_string_literal: true

require "json"
require "sidekiq/api"

module StrictPipeline
  class Scheduler
    JobSpec =
      Struct.new(
        :name,
        :queue,
        :klass,
        :kind,
        :args,
        keyword_init: true
      )

    JOBS = [
      JobSpec.new(
        name: :layer1,
        queue: "layer1_strict",
        klass: "Layer1::StrictTipSyncJob",
        kind: :sidekiq,
        args: []
      ),

      JobSpec.new(
        name: :cluster,
        queue: "cluster_strict",
        klass: "Clusters::StrictTipSyncJob",
        kind: :active_job,
        args: [
          {
            limit: Integer(
              ENV.fetch("CLUSTER_STRICT_SYNC_LIMIT", "2")
            ),
            reschedule: true
          }
        ]
      ),

      JobSpec.new(
        name: :address_spend_projection,
        queue: "address_spend_projection",
        klass: "AddressSpendStats::ProjectionJob",
        kind: :active_job,
        args: [
          {
            limit:
              Integer(
                ENV.fetch(
                  "ADDRESS_SPEND_PROJECTION_JOB_LIMIT",
                  "2"
                )
              ),

            max_runtime_seconds:
              Integer(
                ENV.fetch(
                  "ADDRESS_SPEND_PROJECTION_JOB_MAX_RUNTIME_SECONDS",
                  "15"
                )
              )
          }
        ]
      ),

      JobSpec.new(
        name: :actor_profile,
        queue: "actor_profile_strict",
        klass: "ActorProfiles::StrictBatchJob",
        kind: :active_job,
        args: [
          {
            limit: Integer(
              ENV.fetch("ACTOR_PROFILE_STRICT_BATCH_LIMIT", "5")
            ),
            reschedule: false
          }
        ]
      ),

      JobSpec.new(
        name: :actor_behavior,
        queue: "actor_behavior_strict",
        klass: "ActorBehaviors::StrictBatchJob",
        kind: :active_job,
        args: [
          {
            limit: 25,
            enforce_cooldown: true
          }
        ]
      ),

      JobSpec.new(
        name: :actor_behavior_heavy,
        queue: "actor_behavior_heavy",
        klass: "ActorBehaviors::HeavyBatchJob",
        kind: :active_job_keywords,
        args: [
          {
            limit: 1,
            trigger:
              "strict_pipeline_scheduler"
          }
        ]
      ),

      JobSpec.new(
        name: :actor_labels,
        queue: "actor_labels_strict",
        klass: "ActorLabels::StrictBatchJob",
        kind: :active_job,
        args: [
          {
            limit: Integer(
              ENV.fetch(
                "ACTOR_LABEL_STRICT_BATCH_LIMIT",
                "25"
              )
            ),
            persist_cursor: true
          }
        ]
      )
    ].freeze

    CLUSTER_TRANSACTION_PROJECTION_BACKFILL_JOB =
      JobSpec.new(
        name: :cluster_transaction_projection_backfill,
        queue: "cluster_transaction_projection",
        klass: "ClusterTransactionProjection::BackfillSliceJob",
        kind: :active_job_keywords,
        args: [
          {
            budget_seconds:
              ClusterTransactionProjection::
                OperationalSnapshot
                .scheduler_budget_seconds
          }
        ]
      )

    STRICT_IO_ROLES = %i[layer1 cluster].freeze
    LAYER1_WORKER_SETTLING_WAIT_SECONDS = 2

    DEVELOPMENT_BACKFILL_DOWNSTREAM_QUEUES = %w[
      cluster_strict
      address_spend_projection
      actor_profile_strict
      actor_behavior_strict
      actor_behavior_heavy
      actor_labels_strict
      layer1_audit
      tx_outputs_async
      tx_output_projection
      cluster_coverage
    ].freeze

    def self.call
      new.call
    end

    def call
      @strict_io_owners_scheduled = []
      @actor_behavior_heavy_scheduled = false

      publish_runtime_status
      ensure_actor_labels_worker_capability

      snapshot =
        System::PipelineController.snapshot

      actor_profile_epoch_activation =
        activate_actor_profile_epoch(
          snapshot
        )

      if actor_profile_epoch_activation[
           :status
         ].to_s == "activated"
        snapshot =
          System::PipelineController.snapshot
      end

      results =
        ordered_jobs(
          snapshot
        ).map do |spec|
          schedule_one(
            spec,
            snapshot
          )
        end

      anomaly_watchdog =
        run_anomaly_watchdog

      {
        ok:
          true,

        checked_at:
          Time.current,

        actor_profile_epoch_activation:
          actor_profile_epoch_activation,

        jobs:
          results,

        anomaly_watchdog:
          anomaly_watchdog
      }
    end

    private

    # En development_backfill, le retard relatif de Cluster détermine
    # l'ordre des deux propriétaires strict_io.
    #
    # Au-delà de la marge autorisée pour ActorProfile, Cluster doit
    # réduire son retard avant qu'un nouveau tour Layer1 puisse
    # augmenter à nouveau ce retard.
    def ordered_jobs(snapshot)
      jobs =
        scheduled_jobs

      return jobs unless cluster_strict_priority?(
        snapshot
      )

      cluster =
        jobs.find do |spec|
          spec.name == :cluster
        end

      layer1 =
        jobs.find do |spec|
          spec.name == :layer1
        end

      downstream =
        jobs.reject do |spec|
          %i[
            layer1
            cluster
          ].include?(
            spec.name
          )
        end

      [
        cluster,
        layer1,
        *downstream
      ].compact
    end

    def scheduled_jobs
      return JOBS unless
        ClusterTransactionProjection::
          OperationalSnapshot.enabled?

      [
        *JOBS[0..3],
        CLUSTER_TRANSACTION_PROJECTION_BACKFILL_JOB,
        *JOBS[4..]
      ]
    end

    def cluster_strict_priority?(snapshot)
      return false unless
        System::PipelineController.pipeline_mode ==
          System::PipelineController::
            DEVELOPMENT_BACKFILL_MODE

      cluster_lag =
        snapshot.dig(
          :cluster,
          :lag
        ).to_i

      cluster_lag >
        System::PipelineController::
          ACTOR_PROFILE_MAX_CLUSTER_LAG
    end

    RUNTIME_STATUS_KEY = "strict_pipeline:scheduler:runtime_status"
    RUNTIME_STATUS_TTL_SECONDS = 120
    LAYER1_LAST_ENQUEUE_KEY =
      "strict_pipeline:layer1:last_enqueue"
    LAYER1_LAST_ENQUEUE_TTL_SECONDS = 1.day.to_i

    def publish_runtime_status
      payload = {
        observed_at: Time.current.iso8601(6),
        pid: Process.pid,
        queue: "scheduler",
        scheduler_enabled: true,
        actor_behavior_auto_enabled:
          ActiveModel::Type::Boolean
            .new
            .cast(
              ENV.fetch("ACTOR_BEHAVIOR_AUTO_ENABLED", "false")
            ) == true,

        actor_behavior_heavy_auto_enabled:
          ActiveModel::Type::Boolean
            .new
            .cast(
              ENV.fetch(
                "ACTOR_BEHAVIOR_HEAVY_AUTO_ENABLED",
                "false"
              )
            ) == true,

        actor_behavior_heavy_labels_enabled:
          ActiveModel::Type::Boolean
            .new
            .cast(
              ENV.fetch(
                "ACTOR_BEHAVIOR_HEAVY_LABELS_ENABLED",
                "false"
              )
            ) == true
      }

      Sidekiq.redis do |redis|
        redis.set(
          RUNTIME_STATUS_KEY,
          JSON.generate(payload),
          ex: RUNTIME_STATUS_TTL_SECONDS
        )
      end
    rescue StandardError => error
      Rails.logger.warn(
        "[strict_pipeline_scheduler] runtime_status_save_failed " \
        "#{error.class}: #{error.message}"
      )
    end

    def schedule_one(spec, snapshot)
      decision =
        System::PipelineController.decision(
          spec.name,
          current_snapshot: snapshot
        )

      present =
        job_present?(spec)

      work_available =
        System::PipelineController.work_available?(decision)

      repaired =
        false

      if decision[:allowed] &&
         work_available &&
         actor_behavior_auto_enqueue_allowed?(spec, decision) &&
         actor_behavior_heavy_auto_enqueue_allowed?(spec, decision) &&
         actor_labels_auto_enqueue_allowed?(spec, decision) &&
         !present
        lease = acquire_strict_io_lease(spec)
        return strict_io_denied_result(spec, decision, work_available, present) if strict_io_role?(spec) && lease.nil?

        begin
          @current_enqueue_decision = decision

          if lease
            enqueue(spec, lease: lease)
          else
            enqueue(spec)
          end

          if spec.name ==
             :actor_behavior_heavy
            @actor_behavior_heavy_scheduled =
              true

            ActorBehaviors::Heavy::
              ControlSnapshot.mark_enqueued!
          end
        rescue StandardError
          release_strict_io_lease(lease) if lease
          raise
        ensure
          @current_enqueue_decision = nil
        end
        repaired = true
      end

      settling_retry =
        request_layer1_worker_settling_retry_if_needed(
          spec: spec,
          snapshot: snapshot,
          decision: decision,
          work_available: work_available,
          present: present,
          repaired: repaired
        )

      {
        name: spec.name,
        queue: spec.queue,
        klass: spec.klass,
        allowed: decision[:allowed],
        state: decision[:state],
        reason: decision[:reason],
        work_available:
          work_available,
        present: present,
        repaired: repaired,
        settling_retry: settling_retry,
        active: active_count(spec.queue),
        queued: queued_count(spec.queue),
        scheduled: scheduled_count(spec.queue),
        retry: retry_count(spec.queue)
      }
    end

    def request_layer1_worker_settling_retry_if_needed(
      spec:,
      snapshot:,
      decision:,
      work_available:,
      present:,
      repaired:
    )
      return false unless
        layer1_worker_settling_retry_needed?(
          spec: spec,
          snapshot: snapshot,
          decision: decision,
          work_available: work_available,
          present: present,
          repaired: repaired
        )

      StrictPipeline::SchedulerWakeup.request!(
        reason: "layer1_worker_state_settling",
        wait: LAYER1_WORKER_SETTLING_WAIT_SECONDS.seconds
      )

      true
    rescue StandardError => error
      Rails.logger.warn(
        "[strict_pipeline_scheduler] " \
        "layer1_worker_settling_retry_failed " \
        "#{error.class}: #{error.message}"
      )

      false
    end

    def layer1_worker_settling_retry_needed?(
      spec:,
      snapshot:,
      decision:,
      work_available:,
      present:,
      repaired:
    )
      return false unless spec.name == :layer1
      return false unless decision[:allowed] == true
      return false unless work_available == true
      return false unless present == true
      return false if repaired

      layer1 =
        snapshot.fetch(
          :layer1,
          {}
        )

      return false unless layer1[:lag].to_i.positive?
      return false if layer1[:processing] == true
      return false unless layer1[:strict_queue_size].to_i.zero?
      return false unless layer1[:strict_worker_busy] == true
      return false unless snapshot.dig(:strict_io, :owner).blank?

      active_count("layer1_strict").positive? &&
        queued_count("layer1_strict").to_i.zero? &&
        scheduled_count("layer1_strict").to_i.zero?
    end

    def ensure_actor_labels_worker_capability
      return if actor_labels_worker_status_fresh?
      return unless process_present?("actor_labels_strict")
      return if active_count("actor_labels_strict").positive?
      return if queued_count("actor_labels_strict").positive?
      return if scheduled_count("actor_labels_strict").positive?

      ActorLabels::WorkerCapabilityJob.perform_later
    rescue StandardError => error
      Rails.logger.warn(
        "[strict_pipeline_scheduler] " \
        "actor_labels_worker_capability_enqueue_failed " \
        "#{error.class}: #{error.message}"
      )
    end

    def actor_behavior_auto_enqueue_allowed?(spec, decision)
      return true unless spec.name == :actor_behavior

      decision[:state] == :run &&
        decision.dig(:actor_behavior, :auto_enabled) == true &&
        decision.dig(:actor_behavior, :cooldown_active) != true &&
        decision.dig(:actor_behavior, :batch_running) != true &&
        decision.dig(:actor_behavior, :stale_running_run) != true
    end

    def actor_behavior_heavy_auto_enqueue_allowed?(
      spec,
      decision
    )
      return true unless
        spec.name ==
          :actor_behavior_heavy

      decision[:state] == :run &&
        decision.dig(
          :actor_behavior_heavy,
          :auto_enabled
        ) == true &&
        decision.dig(
          :actor_behavior_heavy,
          :labels_enabled
        ) == true &&
        decision.dig(
          :actor_behavior_heavy,
          :cooldown_active
        ) != true
    end

    def actor_labels_auto_enqueue_allowed?(spec, decision)
      return true unless spec.name == :actor_labels

      return false if
        @actor_behavior_heavy_scheduled

      return false if
        actor_behavior_heavy_present?

      decision[:state] == :run &&
        decision.dig(:actor_labels, :cooldown_active) != true &&
        decision.dig(:actor_labels, :lock_present) != true
    end

    def actor_behavior_heavy_present?
      active_count(
        "actor_behavior_heavy"
      ).positive? ||
        queued_count(
          "actor_behavior_heavy"
        ).positive? ||
        scheduled_count(
          "actor_behavior_heavy"
        ).positive?
    end

    def job_present?(spec)
      active_count(spec.queue).positive? ||
        queued_count(spec.queue).positive? ||
        scheduled_count(spec.queue).positive? ||
        retry_count(spec.queue).positive? ||
        strict_lock_present?(spec)
    end

    def active_count(queue)
      Sidekiq::Workers
        .new
        .count do |_pid, _tid, work|
          h =
            work.instance_variable_get(:@hsh)

          h["queue"] == queue
        end
    end

    def process_present?(queue)
      Sidekiq::ProcessSet
        .new
        .any? do |process|
          Array(process["queues"]).include?(queue) &&
            process["quiet"].to_s != "true"
        end
    rescue StandardError
      false
    end

    def actor_labels_worker_status_fresh?
      ActorLabels::ControlSnapshot
        .call
        .fetch(:worker_write_status_fresh, false) == true
    rescue StandardError
      false
    end

    def queued_count(queue)
      Sidekiq::Queue
        .new(queue)
        .size
    end

    def scheduled_count(queue)
      Sidekiq::ScheduledSet
        .new
        .count { |job| job.queue == queue }
    end

    def retry_count(queue)
      Sidekiq::RetrySet
        .new
        .count { |job| job.queue == queue }
    rescue StandardError
      0
    end

    def enqueue(spec, lease: nil)
      args = args_with_lease(spec, lease)
      mark_scheduled(spec)

      job =
        case spec.kind
        when :sidekiq
          spec.klass.constantize.perform_async(*args)

        when :active_job
          spec.klass.constantize.perform_later(*args)

        when :active_job_keywords
          options =
            (
              args.first || {}
            ).deep_symbolize_keys

          spec
            .klass
            .constantize
            .perform_later(
              **options
            )

        else
          raise "Unknown scheduler kind #{spec.kind.inspect}"
        end

      record_layer1_enqueue(
        spec,
        decision: @current_enqueue_decision,
        job: job
      )

      job
    rescue StandardError
      clear_scheduled_marker(spec)
      raise
    end

    def mark_scheduled(spec)
      return unless
        spec.name ==
          :cluster_transaction_projection_backfill

      ClusterTransactionProjection::
        BackfillSliceJob.mark_scheduled!
    end

    def clear_scheduled_marker(spec)
      return unless
        spec.name ==
          :cluster_transaction_projection_backfill

      ClusterTransactionProjection::
        BackfillSliceJob.clear_scheduled!
    rescue StandardError
      nil
    end

    def strict_io_role?(spec)
      STRICT_IO_ROLES.include?(spec.name)
    end

    def acquire_strict_io_lease(spec)
      return nil unless strict_io_role?(spec)
      return nil unless
        StrictPipeline::StrictIoLease.compatible_owners?(
          spec.name,
          @strict_io_owners_scheduled
        )
      return nil if
        !StrictPipeline::StrictIoMode.concurrent_ssd? &&
        opposite_strict_io_worker_active?(spec)

      if spec.name == :layer1 &&
         development_backfill_alternating_enabled? &&
         development_backfill_downstream_worker_active?
        return nil
      end

      lease =
        StrictPipeline::StrictIoLease.acquire(spec.name)

      @strict_io_owners_scheduled << lease.owner if lease

      lease
    end

    def opposite_strict_io_worker_active?(spec)
      opposite_queue =
        case spec.name
        when :layer1
          "cluster_strict"
        when :cluster
          "layer1_strict"
        end

      return false if opposite_queue.blank?

      active_count(opposite_queue).positive?
    end

    def development_backfill_alternating_enabled?
      System::DevelopmentBackfillPhase
        .configuration
        .fetch(
          :enabled,
          false
        )
    end

    def development_backfill_downstream_worker_active?
      queues =
        DEVELOPMENT_BACKFILL_DOWNSTREAM_QUEUES

      if StrictPipeline::StrictIoMode.concurrent_ssd?
        queues = queues - ["cluster_strict"]
      end

      Sidekiq::Workers
        .new
        .any? do |_pid, _tid, work|
          h =
            work.instance_variable_get(
              :@hsh
            )

          queues
            .include?(
              h["queue"].to_s
            )
        end
    rescue StandardError
      true
    end

    def release_strict_io_lease(lease)
      StrictPipeline::StrictIoLease.release(
        owner: lease.owner,
        token: lease.token
      )

      @strict_io_owners_scheduled.delete(lease.owner)
    end

    def args_with_lease(spec, lease)
      args =
        spec.args.deep_dup

      if spec.name == :actor_profile &&
         System::PipelineController.development_backfill_mode?
        options =
          (args.first || {}).deep_dup

        # ActorProfile conserve toujours une prochaine tentative
        # en development_backfill. Chaque tentative repasse par le
        # PipelineController et cède donc automatiquement devant
        # Layer1, Cluster et AddressSpendProjection.
        options[:reschedule] =
          true

        return [options]
      end

      return args unless lease

      case spec.name
      when :layer1
        [lease.token]

      when :cluster
        options =
          (args.first || {}).deep_dup

        options[:strict_io_token] = lease.token
        options[:strict_io_owner] = lease.owner

        [options]

      else
        args
      end
    end

    def strict_io_denied_result(spec, decision, work_available, present)
      {
        name: spec.name,
        queue: spec.queue,
        klass: spec.klass,
        allowed: false,
        state: :waiting,
        reason: :strict_io_lease_denied,
        work_available: work_available,
        present: present,
        repaired: false,
        active: active_count(spec.queue),
        queued: queued_count(spec.queue),
        scheduled: scheduled_count(spec.queue),
        retry: retry_count(spec.queue)
      }
    end

    def strict_lock_present?(spec)
      if strict_io_role?(spec)
        return true unless
          StrictPipeline::StrictIoLease.compatible_owners?(
            spec.name,
            @strict_io_owners_scheduled
          )

        return !StrictPipeline::StrictIoLease
          .compatible_with_current?(spec.name)
      end

      key =
        case spec.name
        when :actor_profile
          [
            ActorProfiles::StrictBatchJob::LOCK_KEY,
            ActorProfiles::StrictBatchJob::SCHEDULE_KEY
          ]
        when :actor_behavior
          ActorBehaviors::StrictBatchJob::LOCK_KEY
        when :actor_labels
          ActorLabels::StrictBatchJob::LOCK_KEY
        when :cluster_transaction_projection_backfill
          return ClusterTransactionProjection::
            BackfillSliceJob.lock_present?
        end

      return false if key.blank?

      Sidekiq.redis do |redis|
        value =
          if key.is_a?(Array)
            redis.call("EXISTS", *key)
          else
            redis.exists?(key)
          end

        value == true || value.to_i.positive?
      end
    rescue StandardError
      false
    end

    def record_layer1_enqueue(spec, decision:, job:)
      return unless spec.name == :layer1

      payload = {
        enqueued_at: Time.current.iso8601(6),
        reason:
          decision&.fetch(:reason, nil).presence ||
            "strict_pipeline_scheduler",
        queue: spec.queue,
        klass: spec.klass,
        job_id:
          if job.respond_to?(:job_id)
            job.job_id
          else
            job
          end
      }

      Sidekiq.redis do |redis|
        redis.set(
          LAYER1_LAST_ENQUEUE_KEY,
          JSON.generate(payload),
          ex: LAYER1_LAST_ENQUEUE_TTL_SECONDS
        )
      end

      snapshot = decision&.fetch(:snapshot, nil) || {}
      best_height =
        snapshot.dig(:bitcoin_core, :best_height)
      processed_height =
        snapshot.dig(:layer1, :processed_height)
      lag =
        snapshot.dig(:layer1, :lag).to_i

      Rails.logger.info(
        "[layer1_continuous_catchup] " \
        "best_height=#{best_height} " \
        "processed_height=#{processed_height} " \
        "lag=#{lag} " \
        "action=#{lag > 1 ? 'continue' : 'enqueue'} " \
        "next_height=#{processed_height.to_i + 1}"
      )
    rescue StandardError => error
      Rails.logger.warn(
        "[strict_pipeline_scheduler] " \
        "layer1_enqueue_record_failed " \
        "#{error.class}: #{error.message}"
      )
    end

    def activate_actor_profile_epoch(
      snapshot
    )
      ActorProfiles::
        CertificationEpochAutoActivator
        .call(
          snapshot:
            snapshot
        )
    rescue StandardError => error
      Rails.logger.warn(
        "[strict_pipeline_scheduler] "         "actor_profile_epoch_activation_failed "         "#{error.class}: #{error.message}"
      )

      {
        status:
          "error",

        error:
          "#{error.class}: #{error.message}"
      }
    end

    def run_anomaly_watchdog
      System::AnomalyWatchdog.call
    rescue StandardError => error
      Rails.logger.warn(
        "[strict_pipeline_scheduler] anomaly_watchdog_failed " \
        "#{error.class}: #{error.message}"
      )

      {
        ok: false,
        notified: false,
        error: "#{error.class}: #{error.message}"
      }
    end
  end
end
