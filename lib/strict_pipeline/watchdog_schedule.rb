# frozen_string_literal: true

module StrictPipeline
  class WatchdogSchedule
    ENV_NAME = "STRICT_PIPELINE_WATCHDOG_INTERVAL_SECONDS"
    DEFAULT_INTERVAL_SECONDS = 30
    MIN_INTERVAL_SECONDS = 30
    MAX_INTERVAL_SECONDS = 60

    class ConfigurationError < ArgumentError; end

    def self.interval_seconds(env: ENV)
      raw = env[ENV_NAME]
      return DEFAULT_INTERVAL_SECONDS if raw.nil?

      value = begin
        Integer(raw, 10)
      rescue ArgumentError, TypeError
        raise ConfigurationError, "#{ENV_NAME} must be a valid integer"
      end
      unless value.between?(MIN_INTERVAL_SECONDS, MAX_INTERVAL_SECONDS) && (60 % value).zero?
        raise ConfigurationError,
          "#{ENV_NAME} must divide 60 and be between " \
          "#{MIN_INTERVAL_SECONDS} and #{MAX_INTERVAL_SECONDS}"
      end

      value
    end

    def self.cron(env: ENV)
      interval = interval_seconds(env: env)
      return "* * * * *" if interval == 60

      "*/#{interval} * * * * *"
    end
  end
end
