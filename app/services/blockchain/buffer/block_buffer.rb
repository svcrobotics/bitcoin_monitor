# frozen_string_literal: true

module Blockchain
  module Buffer
    class BlockBuffer
      PENDING = "pending"
      ENQUEUED = "enqueued"
      PROCESSING = "processing"
      PROCESSED = "processed"
      FAILED = "failed"

      TIMING_COLUMNS = %i[
        duration_ms
        rpc_duration_ms
        parse_duration_ms
        db_duration_ms
        flush_duration_ms
      ].freeze

      STRICT_METRICS_COLUMN =
        :strict_metrics

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
            {
              last_heartbeat_at: Time.current,
              updated_at: Time.current
            }.merge(timing_attributes(metrics))
          )

          true
        end

        def mark_processed(height, metrics: {})
          block = BlockBufferModel.find_by(height: height)
          return false unless block

          block.update!(
            {
              status: PROCESSED,
              processed_at: Time.current,
              last_heartbeat_at: Time.current,
              error_class: nil,
              error_message: nil,
              updated_at: Time.current
            }
              .merge(
                timing_attributes(metrics)
              )
              .merge(
                strict_metrics_attributes(block, metrics)
              )
          )

          true
        end

        def mark_failed(height, error:, metrics: {})
          block = BlockBufferModel.find_by(height: height)
          return false unless block

          block.update!(
            {
              status: FAILED,
              failed_at: Time.current,
              last_heartbeat_at: Time.current,
              error_class: error.class.name,
              error_message: error.message.to_s.first(2_000),
              updated_at: Time.current
            }
              .merge(
                timing_attributes(metrics)
              )
              .merge(
                strict_metrics_attributes(block, metrics)
              )
          )

          true
        end

        private

        def timing_attributes(metrics)
          source = metrics.to_h.symbolize_keys

          TIMING_COLUMNS.each_with_object({}) do |column, attributes|
            next unless source.key?(column)
            next if source[column].nil?

            attributes[column] = source[column]
          end
        end
        def strict_metrics_attributes(block, metrics)
          return {} unless
            BlockBufferModel
              .column_names
              .include?(
                STRICT_METRICS_COLUMN.to_s
              )

          incoming_metrics =
            normalize_strict_metrics(metrics)

          return {} if incoming_metrics.empty?

          persisted_metrics =
            normalize_strict_metrics(
              block.public_send(
                STRICT_METRICS_COLUMN
              )
            )

          {
            STRICT_METRICS_COLUMN =>
              persisted_metrics.deep_merge(
                incoming_metrics
              )
          }
        end

        def normalize_strict_metrics(metrics)
          JSON.parse(
            metrics
              .to_h
              .deep_stringify_keys
              .to_json
          )
        rescue StandardError
          {}
        end

      end
    end
  end
end
