# frozen_string_literal: true

module Blockchain
  module Flushers
    class SpentOutputFlusherSelector
      TRUE_VALUES = %w[1 true yes on].freeze
      MODES = %i[realtime recovery].freeze

      class << self
        def call(redis: nil, logger: Rails.logger, mode: :recovery)
          build(redis: redis, logger: logger, mode: mode).call
        end

        def build(redis: nil, logger: Rails.logger, mode: :recovery)
          normalized_mode = normalize_mode(mode)
          options = { logger: logger, mode: normalized_mode }
          options[:redis] = redis if redis

          flusher_class.new(**options)
        end

        def flusher_class
          v2_enabled? ? SpentOutputFlusherV2 : SpentOutputFlusher
        end

        def v2_enabled?
          TRUE_VALUES.include?(ENV.fetch("SPENT_OUTPUT_FLUSHER_V2", "0").to_s.downcase)
        end

        def normalize_mode(mode)
          normalized = mode.to_sym
          return normalized if MODES.include?(normalized)

          raise ArgumentError, "unknown spent output flusher mode #{mode.inspect}"
        rescue NoMethodError
          raise ArgumentError, "unknown spent output flusher mode #{mode.inspect}"
        end
      end
    end
  end
end
