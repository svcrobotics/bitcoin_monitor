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
        def mark_enqueued(height)
          block = BlockBufferModel.find_by(height: height)
          return false unless block
          return false unless [PENDING, FAILED].include?(block.status)

          block.update!(
            status: ENQUEUED,
            updated_at: Time.current
          )

          true
        end

        def mark_processing(height)
          block = BlockBufferModel.find_by(height: height)
          return false unless block
          return false unless [PENDING, ENQUEUED, FAILED].include?(block.status)

          block.update!(
            status: PROCESSING,
            processing_started_at: Time.current,
            last_heartbeat_at: Time.current,
            attempts: block.attempts.to_i + 1,
            updated_at: Time.current
          )

          true
        end

        def heartbeat(height, metrics: {})
          block = BlockBufferModel.find_by(height: height)
          return false unless block

          block.update!(
            last_heartbeat_at: Time.current,
            duration_ms: metrics[:duration_ms],
            rpc_duration_ms: metrics[:rpc_duration_ms],
            parse_duration_ms: metrics[:parse_duration_ms],
            flush_duration_ms: metrics[:flush_duration_ms],
            updated_at: Time.current
          )

          true
        end

        def mark_processed(height, metrics: {})
          block = BlockBufferModel.find_by(height: height)
          return false unless block

          block.update!(
            status: PROCESSED,
            processed_at: Time.current,
            duration_ms: metrics[:duration_ms],
            rpc_duration_ms: metrics[:rpc_duration_ms],
            parse_duration_ms: metrics[:parse_duration_ms],
            flush_duration_ms: metrics[:flush_duration_ms],
            error_class: nil,
            error_message: nil,
            updated_at: Time.current
          )

          true
        end

        def mark_failed(height, error:, metrics: {})
          block = BlockBufferModel.find_by(height: height)
          return false unless block

          block.update!(
            status: FAILED,
            failed_at: Time.current,
            duration_ms: metrics[:duration_ms],
            rpc_duration_ms: metrics[:rpc_duration_ms],
            parse_duration_ms: metrics[:parse_duration_ms],
            flush_duration_ms: metrics[:flush_duration_ms],
            error_class: error.class.name,
            error_message: error.message.to_s.first(2_000),
            updated_at: Time.current
          )

          true
        end
      end
    end
  end
end