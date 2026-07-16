# config/initializers/sidekiq_recovery.rb
# frozen_string_literal: true

module TansaLegacySidekiqRecovery
  ENV_KEY = "TANSA_LEGACY_SIDEKIQ_RECOVERY_ENABLED"
  TRUE_VALUES = %w[1 true yes on].freeze
  FALSE_VALUES = %w[0 false no off].freeze

  module_function

  def enabled?(value = ENV[ENV_KEY])
    normalized = value.to_s.strip.downcase
    return false if normalized.empty? || FALSE_VALUES.include?(normalized)
    return true if TRUE_VALUES.include?(normalized)

    raise ArgumentError, "invalid #{ENV_KEY} value"
  end

  def install!
    return false unless enabled?
    return false unless defined?(Sidekiq)

    Sidekiq.configure_server do |config|
      config.on(:startup) do
        begin
          Sidekiq.redis do |redis|
            lock_key = "recovery:startup_enqueue_lock"

            locked =
              redis.set(
                lock_key,
                Process.pid,
                nx: true,
                ex: 60
              )

            unless locked
              Rails.logger.info("[recovery] startup enqueue skipped: lock already present")
              next
            end

            Rails.logger.info("[recovery] startup enqueue")

            RecoveryOrchestratorJob.perform_later
          end
        rescue => e
          Rails.logger.error("[recovery] startup enqueue failed #{e.class} #{e.message}")
        end
      end
    end

    true
  end
end

TansaLegacySidekiqRecovery.install!
