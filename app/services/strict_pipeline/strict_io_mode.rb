# frozen_string_literal: true

module StrictPipeline
  class StrictIoMode
    ENV_KEY = "TANSA_STRICT_IO_MODE"
    SERIALIZED = "serialized"
    CONCURRENT_SSD = "concurrent_ssd"
    MODES = [SERIALIZED, CONCURRENT_SSD].freeze

    def self.current(logger: Rails.logger)
      value = ENV.fetch(ENV_KEY, SERIALIZED).to_s

      return value if MODES.include?(value)

      logger.warn(
        "[strict_io_mode] unknown_value=#{value.inspect} " \
        "fallback=#{SERIALIZED}"
      )

      SERIALIZED
    end

    def self.concurrent_ssd?(logger: Rails.logger)
      current(logger: logger) == CONCURRENT_SSD
    end
  end
end
