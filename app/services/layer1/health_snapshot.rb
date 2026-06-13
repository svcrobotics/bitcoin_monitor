# frozen_string_literal: true

module Layer1
  class HealthSnapshot
    OUTPUTS_KEY = "blockchain:outputs:buffer"
    SPENT_KEY = "blockchain:spent_outputs:buffer"

    LAYER1_QUEUES = %w[
      process
      ingest
      realtime
      btc_realtime
      layer1_drain
      flushers
      spent_resolve
      low
    ].freeze

    def self.call
      new.call
    end

    def call
      redis = Redis.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0"))

      best = BlockBufferModel.maximum(:height).to_i
      processed = BlockBufferModel.where(status: "processed").maximum(:height).to_i
      lag = best - processed

      {
        status: health_status(lag, redis),
        best_height: best,
        processed_height: processed,
        lag: lag,

        buffers: {
          outputs: redis.llen(OUTPUTS_KEY),
          spent: redis.llen(SPENT_KEY)
        },

        counts: {
          block_buffers: BlockBufferModel.count,
          utxo_outputs: UtxoOutput.count,
          cluster_inputs: ClusterInput.count
        },

        cursors: {
          cluster_input_orchestrator: ClusterInputCursor.first&.last_height_processed,
          cluster_scanner: ScannerCursor.find_by(name: "cluster_scan")&.last_blockheight,
          utxo_min_height: UtxoOutput.minimum(:block_height),
          utxo_max_height: UtxoOutput.maximum(:block_height),
          cluster_max_spent_height: ClusterInput.maximum(:spent_block_height)
        },

        queues: sidekiq_queues,
        workers: layer1_workers,
        processes: sidekiq_processes,
        activity: activity(redis, best, processed),

        timestamps: {
          last_processed_block_at: BlockBufferModel.where(status: "processed").maximum(:updated_at),
          last_utxo_at: safe_time(UtxoOutput.maximum(:created_at)),
          last_cluster_input_at: ClusterInput.maximum(:created_at)
        }
      }
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
      end.select do |w|
        LAYER1_QUEUES.include?(w[:queue])
      end
    end

    private

    def health_status(lag, redis)
      outputs = redis.llen(OUTPUTS_KEY)
      spent = redis.llen(SPENT_KEY)

      layer1_drain_size = queue_size("layer1_drain")
      spent_resolve_size = queue_size("spent_resolve")

      return "critical" if lag > 20 || outputs > 500_000 || layer1_drain_size > 100
      return "warning" if lag > 3 || outputs > 200_000 || spent > 50_000 || layer1_drain_size > 10 || spent_resolve_size > 500

      "healthy"
    end

    def sidekiq_queues
      require "sidekiq/api"

      LAYER1_QUEUES.to_h do |name|
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

    def activity(redis, best, processed)
      last_processed_at = BlockBufferModel.where(status: "processed").maximum(:updated_at)
      last_utxo_at = safe_time(UtxoOutput.maximum(:created_at))

      {
        pipeline_state: pipeline_state(redis, best, processed),
        last_processed_seconds_ago: seconds_ago(last_processed_at),
        last_utxo_seconds_ago: seconds_ago(last_utxo_at),
        outputs_buffer: redis.llen(OUTPUTS_KEY),
        spent_buffer: redis.llen(SPENT_KEY),
        layer1_drain_queue: queue_size("layer1_drain"),
        spent_resolve_queue: queue_size("spent_resolve")
      }
    end

    def pipeline_state(redis, best, processed)
      outputs = redis.llen(OUTPUTS_KEY)
      spent = redis.llen(SPENT_KEY)
      lag = best.to_i - processed.to_i
      layer1_drain = queue_size("layer1_drain")
      spent_resolve = queue_size("spent_resolve")

      return "blocked" if lag.positive? && outputs > 500_000
      return "active" if outputs.positive? || spent.positive? || lag.positive? || layer1_drain.positive? || spent_resolve.positive?

      "idle_synced"
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

    def safe_time(time)
      return nil unless time

      time > Time.current ? Time.current : time
    end
  end
end