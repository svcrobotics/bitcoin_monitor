# frozen_string_literal: true

module Blockchain
  module Events
    class EventBuilder
      def initialize(logger: Rails.logger)
        @logger = logger
      end

      def call(event_type, payload)
        Event.create!(
          event_type: event_type.to_s,

          txid: payload[:txid],
          block_height: payload[:block_height],
          block_hash: payload[:block_hash],
          block_time: normalize_time(payload[:block_time]),

          data: payload.except(
            :txid,
            :block_height,
            :block_hash,
            :block_time
          )
        )
      rescue StandardError => e
        @logger.error(
          "[event_builder] error event=#{event_type} #{e.class}: #{e.message}"
        )
      end

      private

      def normalize_time(value)
        return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
        return Time.at(value).in_time_zone if value.present?

        nil
      end
    end
  end
end