# frozen_string_literal: true

module AddressSpendStats
  module Config
    DEFAULT_MAX_ATTEMPTS = 3
    DEFAULT_PROCESSING_STALE_AFTER_SECONDS = 900

    module_function

    def max_attempts
      positive_integer(
        ENV.fetch(
          "ADDRESS_SPEND_PROJECTION_MAX_ATTEMPTS",
          DEFAULT_MAX_ATTEMPTS.to_s
        ),
        DEFAULT_MAX_ATTEMPTS
      )
    end

    def processing_stale_after_seconds
      positive_integer(
        ENV.fetch(
          "ADDRESS_SPEND_PROJECTION_STALE_AFTER_SECONDS",
          DEFAULT_PROCESSING_STALE_AFTER_SECONDS.to_s
        ),
        DEFAULT_PROCESSING_STALE_AFTER_SECONDS
      )
    end

    def positive_integer(value, fallback)
      parsed = Integer(value)

      parsed.positive? ? parsed : fallback
    rescue ArgumentError, TypeError
      fallback
    end
  end
end
