# frozen_string_literal: true

module Layer1
  module Realtime
    class OperationalSnapshot
    STRICT_QUEUE = "layer1_strict"

    OUTPUTS_KEY =
      Blockchain::Buffers::OutputBuffer::KEY

    SPENT_KEY =
      Blockchain::Buffers::SpentOutputBuffer::KEY

    RECENT_CHECKPOINTS_LIMIT = 5

    def self.call
      new.call
    end

    def call
      require "sidekiq/api"

      bitcoin_core_height =
        BitcoinRpc
          .new(wallet: nil)
          .getblockcount
          .to_i

      latest_processed =
        BlockBufferModel
          .where(status: "processed")
          .order(height: :desc)
          .first

      processed_height =
        latest_processed&.height.to_i

      current_block =
        BlockBufferModel
          .where(status: "processing")
          .order(height: :asc)
          .first

      buffers =
        Sidekiq.redis do |redis|
          {
            outputs: redis.llen(OUTPUTS_KEY).to_i,
            spent: redis.llen(SPENT_KEY).to_i
          }
        end

      processes =
        Sidekiq::ProcessSet.new.select do |process|
          Array(process["queues"]).include?(
            STRICT_QUEUE
          )
        end

      queue_size =
        Sidekiq::Queue
          .new(STRICT_QUEUE)
          .size

      busy_workers =
        processes.sum do |process|
          process["busy"].to_i
        end

      lag =
        [
          bitcoin_core_height -
            processed_height,
          0
        ].max

      buffered_items =
        buffers[:outputs] +
        buffers[:spent]

      pipeline_state =
        if current_block.present? ||
           busy_workers.positive?
          "active"
        elsif queue_size.positive?
          "queued"
        elsif lag.zero? &&
              buffered_items.zero?
          "idle_synced"
        elsif processes.empty?
          "worker_missing"
        else
          "waiting"
        end

      current_height =
        current_block&.height

      if current_height.nil? &&
         busy_workers.positive? &&
         lag.positive?
        current_height =
          processed_height + 1
      end

      issues = []

      if processes.empty? &&
         (
           lag.positive? ||
           buffered_items.positive?
         )
        issues << "layer1_strict_worker_missing"
      end

      status =
        if issues.any?
          "critical"
        elsif lag.positive? ||
              buffered_items.positive?
          "warning"
        else
          "healthy"
        end

      recent_checkpoints =
        BlockBufferModel
          .where(status: "processed")
          .order(height: :desc)
          .limit(RECENT_CHECKPOINTS_LIMIT)
          .map do |block|
            processed_at =
              if block.respond_to?(:processed_at)
                block.processed_at
              else
                block.updated_at
              end

            {
              height: block.height.to_i,
              duration_ms:
                block.respond_to?(:duration_ms) ?
                  block.duration_ms.to_i :
                  0,
              processed_at: processed_at
            }
          end

      {
        module: "layer1_health",
        source: "layer1_operational_snapshot",
        generated_at: Time.current,

        status: status,

        bitcoin_core_height:
          bitcoin_core_height,

        processed_height:
          processed_height,

        lag: lag,

        sync: {
          bitcoin_core_height:
            bitcoin_core_height,

          processed_height:
            processed_height,

          lag: lag
        },

        buffers: buffers,

        activity: {
          pipeline_state:
            pipeline_state,

          current_height:
            current_height,

          last_processed_at:
            latest_processed&.updated_at
        },

        queues: {
          STRICT_QUEUE => queue_size
        },

        automation: {
          queue_name:
            STRICT_QUEUE,

          process_present:
            processes.any?,

          process_count:
            processes.size,

          busy_workers:
            busy_workers,

          queue_size:
            queue_size
        },

        recent_checkpoints:
          recent_checkpoints,

        issues: issues
      }
    rescue StandardError => error
      Rails.logger.error(
        "[layer1_operational_snapshot] " \
        "#{error.class}: #{error.message}"
      )

      {
        module: "layer1_health",
        source: "layer1_operational_snapshot",
        generated_at: Time.current,
        status: "critical",

        bitcoin_core_height: nil,
        processed_height: nil,
        lag: nil,

        sync: {
          bitcoin_core_height: nil,
          processed_height: nil,
          lag: nil
        },

        buffers: {
          outputs: 1,
          spent: 1
        },

        activity: {
          pipeline_state: "unknown",
          current_height: nil,
          last_processed_at: nil
        },

        queues: {
          STRICT_QUEUE => 0
        },

        automation: {
          queue_name: STRICT_QUEUE,
          process_present: false,
          process_count: 0,
          busy_workers: 0,
          queue_size: 0
        },

        recent_checkpoints: [],
        issues: ["snapshot_error"],
        error:
          "#{error.class}: #{error.message}"
      }
    end
    end
  end
end
