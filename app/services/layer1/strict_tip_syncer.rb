# frozen_string_literal: true

require "securerandom"

module Layer1
  class StrictTipSyncer
    OUTPUTS_KEY = Blockchain::Buffers::OutputBuffer::KEY
    SPENT_KEY = "blockchain:spent_outputs:buffer"
    LOCK_KEY = "layer1:strict_tip_syncer:lock"

    def self.call(**options)
      new(**options).call
    end

    def initialize(
      rpc: BitcoinRpc.new,
      redis: Redis.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0")),
      logger: Rails.logger,
      max_blocks: ENV.fetch("LAYER1_STRICT_TIP_SYNC_MAX_BLOCKS", "3").to_i,
      lock_ttl: 30.minutes.to_i,
      reorg_check_depth: ENV.fetch("LAYER1_STRICT_REORG_CHECK_DEPTH", "6").to_i
    )
      @rpc = rpc
      @redis = redis
      @logger = logger
      @max_blocks = [max_blocks.to_i, 1].max
      @lock_ttl = lock_ttl.to_i
      @reorg_check_depth = [reorg_check_depth.to_i, 1].max
      @lock_token = SecureRandom.hex(16)
    end

    def call
      return locked_response unless acquire_lock

      started_at = monotonic_ms

      begin
        assert_redis_buffers_empty!

        best_height = @rpc.getblockcount.to_i
        continuous_tip = continuous_processed_tip

        unless continuous_tip
          return {
            ok: false,
            status: "no_processed_checkpoint",
            message: "No processed Layer1 block found. Run an initial strict rebuild first.",
            best_height: best_height
          }
        end

        if continuous_tip > best_height
          return {
            ok: false,
            status: "db_ahead_of_bitcoin_core",
            message: "Database processed tip is above Bitcoin Core tip.",
            best_height: best_height,
            continuous_tip: continuous_tip
          }
        end

        reorg = detect_reorg(
          continuous_tip: continuous_tip,
          best_height: best_height
        )

        if reorg
          @logger.error("[layer1_strict_tip_syncer] reorg_detected #{reorg.inspect}")

          return {
            ok: false,
            status: "reorg_detected",
            best_height: best_height,
            continuous_tip: continuous_tip,
            reorg: reorg,
            duration_ms: monotonic_ms - started_at
          }
        end

        if continuous_tip >= best_height
          return {
            ok: true,
            status: "caught_up",
            best_height: best_height,
            continuous_tip: continuous_tip,
            processed: 0,
            reorg_check_depth: @reorg_check_depth,
            duration_ms: monotonic_ms - started_at
          }
        end

        from_height = continuous_tip + 1
        to_height = [best_height, from_height + @max_blocks - 1].min

        @logger.info(
          "[layer1_strict_tip_syncer] sync_start " \
          "best=#{best_height} continuous_tip=#{continuous_tip} " \
          "from=#{from_height} to=#{to_height} max_blocks=#{@max_blocks} " \
          "reorg_check_depth=#{@reorg_check_depth}"
        )

        result = Layer1::StrictWindowRebuilder.call(
          from_height: from_height,
          to_height: to_height
        )

        after_tip = continuous_processed_tip

        response = {
          ok: result[:ok],
          status: result[:ok] ? "synced_segment" : "failed",
          best_height: best_height,
          previous_continuous_tip: continuous_tip,
          continuous_tip: after_tip,
          from_height: from_height,
          to_height: to_height,
          processed: result[:processed],
          failed: result[:failed],
          reorg_check_depth: @reorg_check_depth,
          duration_ms: monotonic_ms - started_at,
          rebuild: result
        }

        @logger.info("[layer1_strict_tip_syncer] sync_done #{response.inspect}")

        response
      rescue StandardError => e
        @logger.error(
          "[layer1_strict_tip_syncer] error #{e.class}: #{e.message}\n" \
          "#{e.backtrace&.first(20)&.join("\n")}"
        )

        {
          ok: false,
          status: "exception",
          error_class: e.class.name,
          error_message: e.message,
          duration_ms: monotonic_ms - started_at
        }
      ensure
        release_lock
      end
    end

    private


    def recover_pending_buffers!
      outputs_before = @redis.llen(Blockchain::Buffers::OutputBuffer::KEY)
      spent_before = @redis.llen(Blockchain::Buffers::SpentOutputBuffer::KEY)

      return if outputs_before.zero? && spent_before.zero?

      @logger.warn(
        "[layer1_strict_tip_syncer] recovering_pending_buffers " \
        "outputs_before=#{outputs_before} spent_before=#{spent_before}"
      )

      out = Blockchain::Flushers::OutputFlusher.new(redis: @redis).call
      spent =
        Blockchain::Flushers::SpentOutputFlusherSelector.call(
          redis: @redis,
          mode: :recovery
        )

      outputs_after = @redis.llen(Blockchain::Buffers::OutputBuffer::KEY)
      spent_after = @redis.llen(Blockchain::Buffers::SpentOutputBuffer::KEY)

      @logger.warn(
        "[layer1_strict_tip_syncer] recovered_pending_buffers " \
        "outputs_flushed=#{out[:flushed].to_i} " \
        "spent_flushed=#{spent[:flushed].to_i} " \
        "outputs_after=#{outputs_after} spent_after=#{spent_after}"
      )

      return if outputs_after.zero? && spent_after.zero?

      raise(
        "Redis buffers are not empty before strict sync " \
        "outputs=#{outputs_after} spent=#{spent_after}"
      )
    end


    def acquire_lock
      @redis.set(LOCK_KEY, @lock_token, nx: true, ex: @lock_ttl)
    end

    def release_lock
      return unless @redis.get(LOCK_KEY) == @lock_token

      @redis.del(LOCK_KEY)
    rescue StandardError
      nil
    end

    def locked_response
      {
        ok: false,
        status: "locked",
        message: "Layer1 strict tip sync is already running."
      }
    end

    def assert_redis_buffers_empty!
      outputs_remaining = @redis.llen(OUTPUTS_KEY)
      spent_remaining = @redis.llen(SPENT_KEY)

      return if outputs_remaining.zero? && spent_remaining.zero?

      recover_pending_buffers!
    end

    def continuous_processed_tip
      min_height =
        BlockBufferModel
          .where(status: "processed")
          .minimum(:height)

      max_height =
        BlockBufferModel
          .where(status: "processed")
          .maximum(:height)

      return nil unless min_height && max_height

      min_height = min_height.to_i
      max_height = max_height.to_i

      first_missing = first_missing_processed_height(
        from_height: min_height,
        to_height: max_height
      )

      return max_height unless first_missing

      first_missing.to_i - 1
    end

    def first_missing_processed_height(from_height:, to_height:)
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
        from_height.to_i,
        to_height.to_i
      ])

      ActiveRecord::Base.connection.select_value(sql)
    end

    def detect_reorg(continuous_tip:, best_height:)
      min_processed_height =
        BlockBufferModel
          .where(status: "processed")
          .minimum(:height)
          .to_i

      from_height = [
        min_processed_height,
        continuous_tip.to_i - @reorg_check_depth + 1
      ].max

      checked = []

      (from_height..continuous_tip.to_i).each do |height|
        block_buffer =
          BlockBufferModel.find_by(
            height: height,
            status: "processed"
          )

        unless block_buffer
          return {
            type: "processed_block_missing",
            height: height,
            from_height: from_height,
            continuous_tip: continuous_tip,
            best_height: best_height
          }
        end

        core_hash = @rpc.getblockhash(height)
        db_hash = block_buffer.block_hash

        checked << {
          height: height,
          db_hash: db_hash,
          core_hash: core_hash
        }

        next if db_hash == core_hash

        return {
          type: "hash_mismatch",
          height: height,
          db_hash: db_hash,
          core_hash: core_hash,
          from_height: from_height,
          continuous_tip: continuous_tip,
          best_height: best_height,
          checked: checked
        }
      end

      nil
    end

    def monotonic_ms
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).round
    end
  end
end
