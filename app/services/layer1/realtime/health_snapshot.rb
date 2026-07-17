# frozen_string_literal: true

require "json"

module Layer1
  module Realtime
    class HealthSnapshot
      OUTPUTS_KEY = "blockchain:outputs:buffer"
      SPENT_KEY = "blockchain:spent_outputs:buffer"
      STRICT_QUEUE = "layer1_strict"
      STRICT_CRON_NAME = "layer1_strict_tip_sync_kick"
      SCHEDULER_QUEUE = "scheduler"
      LOCK_KEY = Layer1::StrictTipSyncer::LOCK_KEY
      SCHEDULER_RUNTIME_STATUS_KEY =
        "strict_pipeline:scheduler:runtime_status"
      LAYER1_LAST_ENQUEUE_KEY =
        "strict_pipeline:layer1:last_enqueue"
      LAYER1_STALLED_SINCE_KEY =
        "strict_pipeline:layer1:stalled_since"
      SCHEDULER_HEARTBEAT_STALE_SECONDS = 60
      LAYER1_STALLED_LAG_BLOCKS = 10
      LAYER1_STALLED_SECONDS = 60

      DISPLAY_QUEUES = %w[
        layer1_strict
        process
        ingest
        realtime
        btc_realtime
        layer1_drain
        flushers
        spent_resolve
        low
      ].freeze

      PROCESSING_STALE_SECONDS =
        ENV.fetch("LAYER1_PROCESSING_STALE_SECONDS", "300").to_i

      def self.call
        new.call
      end

      def call
        redis = Redis.new(
          url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0")
        )

        node_tip, rpc_error = bitcoin_core_tip
        db_best = BlockBufferModel.maximum(:height).to_i
        processed = continuous_processed_tip.to_i
        lag = node_tip ? [node_tip - processed, 0].max : nil

        failed_block = pending_failed_block(processed)
        processing_block = current_processing_block
        processing_stale_seconds = processing_age_seconds(processing_block)
        worker = strict_worker_process
        scheduler = strict_scheduler_snapshot
        scheduler_process = queue_process(SCHEDULER_QUEUE)
        scheduler_runtime = scheduler_runtime_status(redis)
        lock = lock_snapshot(redis)
        strict_queue_size = queue_size(STRICT_QUEUE)
        strict_scheduled_jobs = scheduled_queue_size(STRICT_QUEUE)
        strict_retry_jobs = retry_queue_size(STRICT_QUEUE)
        buffers = buffer_snapshot(redis)
        workers = layer1_workers
        layer1_work_active =
          processing_block.present? ||
          workers.any?

        layer1_work_queued =
          strict_queue_size.to_i.positive? ||
          strict_scheduled_jobs.to_i.positive? ||
          strict_retry_jobs.to_i.positive?

        stalled =
          layer1_stall_snapshot(
            redis: redis,
            lag: lag,
            layer1_work_active: layer1_work_active,
            layer1_work_queued: layer1_work_queued
          )

        last_enqueue =
          layer1_last_enqueue(redis)

        status = health_status(
          rpc_error: rpc_error,
          lag: lag,
          buffers: buffers,
          failed_block: failed_block,
          processing_block: processing_block,
          processing_stale_seconds: processing_stale_seconds,
          worker: worker,
          scheduler: scheduler,
          scheduler_process: scheduler_process,
          lock: lock,
          strict_queue_size: strict_queue_size
        )

        {
          status: status,
          best_height: node_tip,
          bitcoin_core_height: node_tip,
          db_best_height: db_best,
          processed_height: processed,
          lag: lag,
          rpc_error: rpc_error,

          buffers: buffers,

          strict: {
            worker: worker,
            scheduler: scheduler,
            scheduler_process: scheduler_process,
            scheduler_configured:
              scheduler[:registered] == true &&
                scheduler[:enabled] == true,
            scheduler_alive:
              scheduler_runtime[:alive] == true,
            last_scheduler_tick_at:
              scheduler_runtime[:observed_at],
            scheduler_runtime:
              scheduler_runtime.except(:alive, :observed_at),
            lock: lock,
            queue_size: strict_queue_size,
            scheduled_jobs: strict_scheduled_jobs,
            retry_jobs: strict_retry_jobs,
            catch_up_active:
              development_backfill_phase(redis) == "layer1_catchup",
            layer1_work_active: layer1_work_active,
            layer1_work_queued: layer1_work_queued,
            last_enqueue_at:
              last_enqueue["enqueued_at"],
            last_enqueue_reason:
              last_enqueue["reason"],
            stalled:
              stalled[:stalled],
            stalled_since:
              stalled[:stalled_since],
            stalled_seconds:
              stalled[:stalled_seconds],
            stalled_reason:
              stalled[:reason],
            anomaly:
              stalled[:stalled] ? "layer1_stalled" : nil,
            processing_block: block_state(processing_block),
            processing_stale_seconds: processing_stale_seconds,
            failed_block: block_state(failed_block)
          },

          counts: {
            block_buffers: BlockBufferModel.count,
            utxo_outputs: estimated_table_count("utxo_outputs"),
            cluster_inputs: estimated_table_count("cluster_inputs"),

            accuracy: {
              block_buffers: "exact",
              utxo_outputs: "estimated",
              cluster_inputs: "estimated"
            }
          },

          cursors: {
            cluster_input_orchestrator: ClusterInputCursor.first&.last_height_processed,
            cluster_scanner: ScannerCursor.find_by(name: "cluster_scan")&.last_blockheight,
            utxo_min_height: UtxoOutput.minimum(:block_height),
            utxo_max_height: UtxoOutput.maximum(:block_height),
            cluster_max_spent_height: ClusterInput.maximum(:spent_block_height)
          },

          queues: sidekiq_queues,
          workers: workers,
          processes: sidekiq_processes,

          activity: activity(
            redis: redis,
            node_tip: node_tip,
            processed: processed,
            lag: lag,
            failed_block: failed_block,
            processing_block: processing_block,
            processing_stale_seconds: processing_stale_seconds,
            worker: worker,
            scheduler: scheduler,
            scheduler_process: scheduler_process,
            lock: lock,
            strict_queue_size: strict_queue_size
          ),

          timestamps: {
            last_processed_block_at:
              BlockBufferModel.where(status: "processed").maximum(:updated_at),
            last_utxo_at: safe_time(latest_created_at(UtxoOutput)),
            last_cluster_input_at: safe_time(latest_created_at(ClusterInput))
          }
        }
      end

      private

      def bitcoin_core_tip
        [BitcoinRpc.new.getblockcount.to_i, nil]
      rescue StandardError => e
        [nil, "#{e.class}: #{e.message}"]
      end

      def continuous_processed_tip
        min_height = BlockBufferModel.where(status: "processed").minimum(:height)
        max_height = BlockBufferModel.where(status: "processed").maximum(:height)

        return 0 unless min_height && max_height

        table_name = BlockBufferModel.table_name

        sql = ActiveRecord::Base.sanitize_sql_array([
          <<~SQL.squish,
            SELECT MIN(g.height)
            FROM generate_series(?, ?) AS g(height)
            LEFT JOIN #{table_name} b
              ON b.height = g.height
             AND b.status = 'processed'
            WHERE b.id IS NULL
          SQL
          min_height.to_i,
          max_height.to_i
        ])

        first_missing = ActiveRecord::Base.connection.select_value(sql)
        first_missing ? first_missing.to_i - 1 : max_height.to_i
      end

      def pending_failed_block(processed)
        BlockBufferModel
          .where(status: "failed")
          .where("height > ?", processed.to_i)
          .order(height: :asc)
          .first
      end

      def current_processing_block
        BlockBufferModel
          .where(status: "processing")
          .order(height: :asc)
          .first
      end

      def processing_age_seconds(block)
        return nil unless block

        heartbeat =
          block.last_heartbeat_at ||
          block.updated_at ||
          block.processing_started_at

        seconds_ago(heartbeat)
      end

      def health_status(
        rpc_error:,
        lag:,
        buffers:,
        failed_block:,
        processing_block:,
        processing_stale_seconds:,
        worker:,
        scheduler:,
        scheduler_process:,
        lock:,
        strict_queue_size:
      )
        return "critical" if rpc_error.present?
        return "critical" unless worker[:present]
        return "critical" unless scheduler[:registered] && scheduler[:enabled]
        return "critical" unless scheduler_process[:present]
        return "critical" if failed_block.present?

        orphaned_lock =
          lag.to_i.positive? &&
          lock[:present] &&
          !worker[:busy].to_i.positive? &&
          strict_queue_size.to_i.zero?

        return "critical" if orphaned_lock

        if processing_block &&
           processing_stale_seconds.to_i > PROCESSING_STALE_SECONDS
          return "critical"
        end

        # Un retard, même supérieur à trois blocs, ne signifie pas que
        # le pipeline est bloqué lorsqu'il reste opérationnel. Les états
        # critiques sont réservés aux défaillances techniques ci-dessus.
        return "critical" if buffers[:outputs] > 500_000
        return "critical" if queue_size("layer1_drain") > 100

        return "warning" if lag.to_i > 1
        return "warning" if buffers[:outputs] > 200_000
        return "warning" if buffers[:spent] > 50_000
        return "warning" if queue_size("layer1_drain") > 10
        return "warning" if queue_size("spent_resolve") > 500

        "healthy"
      end

      def buffer_snapshot(redis)
        {
          outputs: redis.llen(OUTPUTS_KEY),
          spent: redis.llen(SPENT_KEY)
        }
      end

      def strict_worker_process
        queue_process(STRICT_QUEUE)
      end

      def queue_process(queue_name)
      require "sidekiq/api"

        matching_processes =
          Sidekiq::ProcessSet.new.select do |candidate|
            Array(candidate["queues"]).include?(queue_name)
          end

        active_processes =
          matching_processes.reject do |candidate|
            candidate["quiet"].to_s == "true"
          end

        if active_processes.empty?
          return {
            present: false,
            process_count: 0,
            stopping_process_count: matching_processes.size
          }
        end

        representative =
          active_processes.max_by do |candidate|
            [
              candidate["busy"].to_i,
              candidate["pid"].to_i
            ]
          end

        {
          present: true,
          pid: representative["pid"],
          busy:
            active_processes.sum do |candidate|
              candidate["busy"].to_i
            end,
          concurrency:
            active_processes.sum do |candidate|
              candidate["concurrency"].to_i
            end,
          queues: representative["queues"],
          process_count: active_processes.size,
          stopping_process_count:
            matching_processes.size - active_processes.size
        }
      rescue StandardError => e
        { present: false, error: e.message }
      end

      def lock_snapshot(redis)
        {
          present: redis.exists?(LOCK_KEY),
          ttl_seconds: redis.ttl(LOCK_KEY)
        }
      rescue StandardError => e
        { present: false, ttl_seconds: nil, error: e.message }
      end

      def strict_scheduler_snapshot
        require "sidekiq/cron/job"

        job = Sidekiq::Cron::Job.find(STRICT_CRON_NAME)
        return { registered: false, enabled: false } unless job

        status = job.status.to_s

        {
          registered: true,
          enabled: status != "disabled",
          status: status,
          cron: job.cron
        }
      rescue StandardError => e
        { registered: false, enabled: false, error: e.message }
      end

      def scheduler_runtime_status(redis)
        payload =
          parse_json(
            redis.get(SCHEDULER_RUNTIME_STATUS_KEY)
          )

        observed_at =
          safe_time(parse_time(payload["observed_at"]))

        age =
          seconds_ago(observed_at)

        payload.merge(
          observed_at: observed_at&.iso8601(6),
          heartbeat_age_seconds: age,
          alive:
            observed_at.present? &&
              age.to_i <= SCHEDULER_HEARTBEAT_STALE_SECONDS
        ).symbolize_keys
      rescue StandardError => e
        {
          alive: false,
          observed_at: nil,
          error: e.message
        }
      end

      def layer1_last_enqueue(redis)
        parse_json(
          redis.get(LAYER1_LAST_ENQUEUE_KEY)
        )
      rescue StandardError
        {}
      end

      def development_backfill_phase(redis)
        parse_json(
          redis.get(System::DevelopmentBackfillPhase::STATE_KEY)
        ).fetch("phase", nil).to_s
      rescue StandardError
        nil
      end

      def layer1_stall_snapshot(
        redis:,
        lag:,
        layer1_work_active:,
        layer1_work_queued:
      )
        condition =
          lag.to_i >= LAYER1_STALLED_LAG_BLOCKS &&
          layer1_work_active != true &&
          layer1_work_queued != true

        unless condition
          redis.del(LAYER1_STALLED_SINCE_KEY)

          return {
            stalled: false,
            stalled_since: nil,
            stalled_seconds: 0,
            reason: nil
          }
        end

        now = Time.current
        raw = redis.get(LAYER1_STALLED_SINCE_KEY)

        unless raw.present?
          raw = now.iso8601(6)
          redis.set(LAYER1_STALLED_SINCE_KEY, raw)
        end

        stalled_since =
          safe_time(parse_time(raw)) || now

        stalled_seconds =
          seconds_ago(stalled_since).to_i

        {
          stalled:
            stalled_seconds > LAYER1_STALLED_SECONDS,
          stalled_since:
            stalled_since.iso8601(6),
          stalled_seconds: stalled_seconds,
          reason:
            "lag_without_strict_work"
        }
      rescue StandardError => e
        {
          stalled: false,
          stalled_since: nil,
          stalled_seconds: 0,
          reason: "stall_snapshot_failed",
          error: e.message
        }
      end

      def scheduled_queue_size(queue_name)
        require "sidekiq/api"

        Sidekiq::ScheduledSet.new.count do |job|
          job.queue.to_s == queue_name.to_s
        end
      rescue StandardError
        0
      end

      def retry_queue_size(queue_name)
        require "sidekiq/api"

        Sidekiq::RetrySet.new.count do |job|
          job.queue.to_s == queue_name.to_s
        end
      rescue StandardError
        0
      end

      def layer1_workers
        require "sidekiq/api"
        require "json"

        Sidekiq::Workers.new.map do |_process_id, _thread_id, work|
          h = work.instance_variable_get(:@hsh)
          payload = JSON.parse(h["payload"]) rescue {}

          {
            queue: h["queue"],
            klass: payload["wrapped"].presence || payload["class"],
            args: payload["args"]
          }
        end.select do |worker|
          worker[:queue].to_s == STRICT_QUEUE
        end
      rescue StandardError
        []
      end

      def sidekiq_queues
        require "sidekiq/api"

        DISPLAY_QUEUES.to_h do |name|
          [name, Sidekiq::Queue.new(name).size]
        end
      rescue StandardError => e
        { error: e.message }
      end

      def sidekiq_processes
        require "sidekiq/api"

        Sidekiq::ProcessSet.new.map do |process|
          {
            pid: process["pid"],
            queues: process["queues"],
            busy: process["busy"],
            concurrency: process["concurrency"]
          }
        end
      rescue StandardError => e
        [{ error: e.message }]
      end

      def activity(
        redis:,
        node_tip:,
        processed:,
        lag:,
        failed_block:,
        processing_block:,
        processing_stale_seconds:,
        worker:,
        scheduler:,
        scheduler_process:,
        lock:,
        strict_queue_size:
      )
        last_activity_at =
          last_activity_at(processing_block)

        last_processed_at =
          latest_processed_activity_at

        last_utxo_at = safe_time(latest_created_at(UtxoOutput))

        {
          pipeline_state: pipeline_state(
            lag: lag,
            failed_block: failed_block,
            processing_block: processing_block,
            processing_stale_seconds: processing_stale_seconds,
            worker: worker,
            scheduler: scheduler,
            scheduler_process: scheduler_process,
            lock: lock,
            strict_queue_size: strict_queue_size,
            redis: redis
          ),
          bitcoin_core_height: node_tip,
          processed_height: processed,
          last_activity_at: last_activity_at,
          last_activity_seconds_ago: seconds_ago(last_activity_at),
          last_processed_seconds_ago: seconds_ago(last_processed_at),
          last_utxo_seconds_ago: seconds_ago(last_utxo_at),
          outputs_buffer: redis.llen(OUTPUTS_KEY),
          spent_buffer: redis.llen(SPENT_KEY),
          layer1_strict_queue: strict_queue_size,
          layer1_drain_queue: queue_size("layer1_drain"),
          spent_resolve_queue: queue_size("spent_resolve")
        }
      end

      def last_activity_at(processing_block)
        heartbeat =
          processing_block&.last_heartbeat_at

        return safe_past_time(heartbeat) if safe_past_time(heartbeat)

        processed =
          latest_processed_activity_at

        return processed if processed

        safe_past_time(processing_block&.updated_at)
      end

      def latest_processed_activity_at
        row =
          BlockBufferModel
            .where(status: "processed")
            .order(height: :desc)
            .pick(:processed_at, :updated_at)

        return nil unless row

        processed_at, updated_at = row

        safe_past_time(processed_at) ||
          safe_past_time(updated_at)
      end

      def safe_past_time(time)
        return nil unless time

        value =
          time.respond_to?(:in_time_zone) ? time.in_time_zone : time

        return nil if value > Time.current

        value
      end

      def pipeline_state(
        lag:,
        failed_block:,
        processing_block:,
        processing_stale_seconds:,
        worker:,
        scheduler:,
        scheduler_process:,
        lock:,
        strict_queue_size:,
        redis:
      )
        return "blocked_failed" if failed_block.present?

        if processing_block &&
           processing_stale_seconds.to_i > PROCESSING_STALE_SECONDS
          return "blocked_stale_processing"
        end

        return "blocked_no_worker" unless worker[:present]
        return "blocked_no_scheduler" unless scheduler[:registered] && scheduler[:enabled]
        return "blocked_no_scheduler_process" unless scheduler_process[:present]

        orphaned_lock =
          lag.to_i.positive? &&
          lock[:present] &&
          !worker[:busy].to_i.positive? &&
          strict_queue_size.to_i.zero?

        return "blocked_orphaned_lock" if orphaned_lock

        outputs = redis.llen(OUTPUTS_KEY)
        spent = redis.llen(SPENT_KEY)

        return "active" if processing_block.present?
        return "active" if lag.to_i.positive?
        return "active" if outputs.positive? || spent.positive?
        return "active" if strict_queue_size.positive?

        "idle_synced"
      end

      def block_state(block)
        return nil unless block

        block.attributes.slice(
          "height",
          "status",
          "processing_started_at",
          "last_heartbeat_at",
          "processed_at",
          "updated_at",
          "failed_at",
          "error_class",
          "error_message"
        )
      end

      def seconds_ago(time)
        return nil unless time

        seconds = (Time.current - time).to_i
        seconds.negative? ? 0 : seconds
      end

      def queue_size(name)
        require "sidekiq/api"

        Sidekiq::Queue.new(name).size
      rescue StandardError
        0
      end

      def estimated_table_count(table_name)
        sql =
          ActiveRecord::Base.sanitize_sql_array(
            [
              <<~SQL.squish,
                SELECT
                  GREATEST(reltuples, 0)::bigint
                FROM pg_class
                WHERE oid = ?::regclass
              SQL
              table_name
            ]
          )

        ActiveRecord::Base
          .connection
          .select_value(sql)
          &.to_i
      rescue StandardError
        nil
      end

      def latest_created_at(model)
        model
          .order(id: :desc)
          .limit(1)
          .pick(:created_at)
      rescue StandardError
        nil
      end

      def safe_time(time)
        return nil unless time

        time > Time.current ? Time.current : time
      end

      def parse_json(raw)
        return {} if raw.blank?

        JSON.parse(raw)
      rescue JSON::ParserError
        {}
      end

      def parse_time(value)
        return nil if value.blank?

        Time.zone.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
