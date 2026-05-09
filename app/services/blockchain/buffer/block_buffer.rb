# frozen_string_literal: true

module Blockchain
  module Buffer
    class BlockBuffer
      PENDING = "pending"
      ENQUEUED = "enqueued"
      PROCESSING = "processing"
      PROCESSED = "processed"
      FAILED = "failed"

      class << self

        def heartbeat(height, metrics: {})
          BlockBufferModel
            .where(height: height)
            .update_all(
              {
                last_heartbeat_at: Time.current,
                updated_at: Time.current
              }.merge(metrics)
            )
        end

        def insert(block)
          Blockchain::Ingest::BlockIngestService.new.call(block.fetch("hash"))
        end

        def exists?(block_hash)
          BlockBufferModel.exists?(block_hash: block_hash)
        end

        def next_pending
          BlockBufferModel
            .where(status: PENDING)
            .order(:height)
            .first
        end

        def next_processable
          BlockBufferModel
            .where(status: [PENDING, FAILED])
            .order(:height)
            .first
        end

        def mark_enqueued(height)
          transition(height, from: [PENDING, FAILED], to: ENQUEUED)
        end

        def mark_processing(height)
          affected =
            BlockBufferModel
              .where(height: height, status: [ENQUEUED, PENDING, FAILED])
              .update_all(
                status: PROCESSING,
                processing_started_at: Time.current,
                last_heartbeat_at: Time.current,
                attempts: Arel.sql("attempts + 1"),
                updated_at: Time.current
              )

          affected.positive?
        end

        def mark_processed(height, metrics: {})
          BlockBufferModel
            .where(height: height)
            .update_all(
              {
                status: PROCESSED,
                processed_at: Time.current,
                failed_at: nil,
                error_class: nil,
                error_message: nil,
                last_heartbeat_at: Time.current,
                updated_at: Time.current
              }.merge(metrics)
            )
        end

        def mark_failed(height, error: nil, metrics: {})
          attrs = {
            status: FAILED,
            failed_at: Time.current,
            last_heartbeat_at: Time.current,
            updated_at: Time.current
          }.merge(metrics)

          if error
            attrs[:error_class] = error.class.name
            attrs[:error_message] = error.message.truncate(2_000)
          end

          BlockBufferModel
            .where(height: height)
            .update_all(attrs)
        end

        def reset_failed(height)
          transition(height, from: [FAILED], to: PENDING)
        end

        def pending_count
          BlockBufferModel.where(status: PENDING).count
        end

        def failed_count
          BlockBufferModel.where(status: FAILED).count
        end

        def last_processed_height
          BlockBufferModel.where(status: PROCESSED).maximum(:height)
        end

        def highest_buffered_height
          BlockBufferModel.maximum(:height)
        end

        def lag_from_tip(tip_height)
          last_height = last_processed_height || highest_buffered_height
          return nil unless last_height

          tip_height.to_i - last_height.to_i
        end

        private

        def transition(height, from:, to:)
          affected =
            BlockBufferModel
              .where(height: height, status: from)
              .update_all(status: to, updated_at: Time.current)

          affected.positive?
        end

        def update_status(height, status)
          BlockBufferModel
            .where(height: height)
            .update_all(status: status, updated_at: Time.current)
        end
      end
    end
  end
end