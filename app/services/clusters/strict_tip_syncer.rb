# frozen_string_literal: true

require "securerandom"
require "set"

module Clusters
  class StrictTipSyncer
    LOCK_KEY = "clusters:strict_tip_syncer:lock"
    LOCK_TTL =
      Integer(
      ENV.fetch(
      "CLUSTER_STRICT_SYNCER_LOCK_TTL_SECONDS",
      "3600"
      )
      )

    DEFAULT_LIMIT = Integer(ENV.fetch("CLUSTER_STRICT_SYNC_LIMIT", "2"))

    def self.call(
      limit: nil,
      start_height: nil,
      yield_guard: nil,
      max_runtime_seconds: nil,
      logger: Rails.logger
    )
      StrictPipeline::PostgresWriteBarrier.with_lock(
        owner: "cluster",
        logger: logger
      ) do
        new(
          limit: limit,
          start_height: start_height,
          yield_guard: yield_guard,
          max_runtime_seconds: max_runtime_seconds,
          logger: logger
        ).call
      end
    rescue StrictPipeline::PostgresWriteBarrier::LockUnavailable => error
      logger.info(
        "[cluster_strict_tip_syncer] " \
        "skipped reason=postgres_write_barrier_locked " \
        "message=#{error.message}"
      )

      {
        ok: true,
        status: "skipped",
        reason: "postgres_write_barrier_locked",
        message: error.message
      }
    end

    def initialize(limit: nil, start_height: nil, yield_guard: nil, max_runtime_seconds: nil, logger: Rails.logger)
      @limit = (limit || DEFAULT_LIMIT).to_i
      @start_height = start_height&.to_i
      @yield_guard = yield_guard
      @max_runtime_seconds = max_runtime_seconds&.to_i
      @logger = logger
      @redis = Redis.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0"))
      @lock_token = SecureRandom.uuid
      @lock_acquired = false
    end

    def call
      return skipped("lock already present") unless acquire_lock!

      started_at = monotonic_ms

      cluster_tip = cluster_processed_tip
      layer1_tip = layer1_processed_tip

      return failure("no Layer1 processed block found") unless layer1_tip

      continuity_error = cluster_continuity_error
      return continuity_error if continuity_error

      reorg_error = detect_reorg(cluster_tip)
      return reorg_error if reorg_error

      next_height =
        if cluster_tip
          cluster_tip + 1
        else
          @start_height || Integer(ENV.fetch("CLUSTER_STRICT_START_HEIGHT"))
        end

      return idle(cluster_tip, layer1_tip) if next_height > layer1_tip

      to_height = [next_height + @limit - 1, layer1_tip].min

      missing_layer1 = missing_layer1_processed_heights(next_height, to_height)

      if missing_layer1.any?
        return failure(
          "Layer1 processed gap",
          extra: {
            from_height: next_height,
            to_height: to_height,
            missing_layer1_processed_heights: missing_layer1.first(20)
          }
        )
      end

      rebuild =
        Clusters::StrictWindowRebuilder.call(
          from_height: next_height,
          to_height: to_height,
          yield_guard: @yield_guard,
          max_runtime_seconds: @max_runtime_seconds,
          slice_started_at_ms: started_at
        )

      {
        ok: rebuild[:ok],
        status:
          if rebuild[:status].to_s == "yielded_to_layer1"
            "yielded_to_layer1"
          elsif rebuild[:ok]
            "synced"
          else
            "failed"
          end,
        cluster_tip_before: cluster_tip,
        cluster_tip_after: cluster_processed_tip,
        layer1_tip: layer1_tip,
        from_height: next_height,
        to_height: to_height,
        limit: @limit,
        rebuild: rebuild
      }
    ensure
      release_lock! if @lock_acquired
    end

    private

    def monotonic_ms
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).to_i
    end

    def cluster_processed_tip
      ClusterProcessedBlock.where(status: "processed").maximum(:height)
    end

    def layer1_processed_tip
      BlockBufferModel.where(status: "processed").maximum(:height)
    end

    def cluster_continuity_error
      min_height = ClusterProcessedBlock.where(status: "processed").minimum(:height)
      max_height = ClusterProcessedBlock.where(status: "processed").maximum(:height)

      return nil unless min_height && max_height

      expected_count = max_height - min_height + 1

      actual_count =
        ClusterProcessedBlock
          .where(status: "processed", height: min_height..max_height)
          .distinct
          .count(:height)

      return nil if expected_count == actual_count

      existing =
        ClusterProcessedBlock
          .where(status: "processed", height: min_height..max_height)
          .pluck(:height)
          .to_set

      missing =
        (min_height..max_height).reject { |height| existing.include?(height) }

      failure(
        "Cluster processed blocks are not continuous",
        extra: {
          min_height: min_height,
          max_height: max_height,
          expected_count: expected_count,
          actual_count: actual_count,
          missing_heights: missing.first(20)
        }
      )
    end

    def detect_reorg(cluster_tip)
      return nil unless cluster_tip

      depth = Integer(ENV.fetch("CLUSTER_STRICT_REORG_CHECK_DEPTH", "6"))
      from_height = [cluster_tip - depth + 1, 0].max

      rows =
        ClusterProcessedBlock
          .where(status: "processed", height: from_height..cluster_tip)
          .order(:height)
          .pluck(:height, :block_hash)

      rows.each do |height, cluster_hash|
        layer1_block = BlockBufferModel.find_by(height: height, status: "processed")

        unless layer1_block
          return failure(
            "Layer1 block missing during reorg check",
            extra: { height: height }
          )
        end

        next if layer1_block.block_hash == cluster_hash

        return failure(
          "reorg_detected",
          extra: {
            height: height,
            cluster_hash: cluster_hash,
            layer1_hash: layer1_block.block_hash
          }
        )
      end

      nil
    end

    def missing_layer1_processed_heights(from_height, to_height)
      existing =
        BlockBufferModel
          .where(status: "processed", height: from_height..to_height)
          .pluck(:height)
          .to_set

      (from_height..to_height).reject { |height| existing.include?(height) }
    end

    def acquire_lock!
      result = @redis.set(LOCK_KEY, @lock_token, nx: true, ex: LOCK_TTL)
      @lock_acquired = result == true || result == "OK"
    end

    def release_lock!
      return unless @redis.get(LOCK_KEY) == @lock_token

      @redis.del(LOCK_KEY)
    end

    def skipped(reason)
      {
        ok: true,
        status: "skipped",
        reason: reason
      }
    end

    def idle(cluster_tip, layer1_tip)
      {
        ok: true,
        status: "idle",
        reason: "cluster already caught up with Layer1",
        cluster_tip: cluster_tip,
        layer1_tip: layer1_tip,
        lag: layer1_tip.to_i - cluster_tip.to_i
      }
    end

    def failure(message, extra: {})
      result = {
        ok: false,
        status: "failed",
        message: message
      }.merge(extra)

      @logger.error("[cluster_strict_tip_syncer] #{result.inspect}")

      result
    end
  end
end
