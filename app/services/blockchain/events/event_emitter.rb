# frozen_string_literal: true

module Blockchain
  module Events
    class EventEmitter
      @subscribers = Hash.new { |h, k| h[k] = [] }
      @mutex = Mutex.new

      class << self
        # -----------------------------
        # SUBSCRIBE
        # -----------------------------
        def subscribe(event_name, handler = nil, &block)
          handler ||= block
          raise ArgumentError, "handler required" unless handler

          key = normalize(event_name)

          @mutex.synchronize do
            @subscribers[key] << handler
          end
        end

        # -----------------------------
        # EMIT
        # -----------------------------
        def emit(event_name, payload)
          key = normalize(event_name)

          handlers = @subscribers[key]
          return if handlers.empty?

          handlers.each do |handler|
            handler.call(payload)
          rescue StandardError => e
            Rails.logger.error(
              "[event_emitter] handler_error event=#{key} #{e.class}: #{e.message}"
            )
          end
        end

        # -----------------------------
        # DEBUG
        # -----------------------------
        def subscribers_for(event_name)
          @subscribers[normalize(event_name)]
        end

        def reset!
          @mutex.synchronize do
            @subscribers.clear
          end
        end

        private

        def normalize(event_name)
          event_name.to_sym
        end
      end
    end
  end
end