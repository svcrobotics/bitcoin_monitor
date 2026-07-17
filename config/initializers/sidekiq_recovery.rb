# config/initializers/sidekiq_recovery.rb
# frozen_string_literal: true

if ENV["LAYER1_STRICT_ONLY"] == "1"
  Rails.logger.info("[recovery] disabled because LAYER1_STRICT_ONLY=1") if defined?(Rails)
elsif ENV["SIDEKIQ_RECOVERY_ENABLED"] != "1"
  Rails.logger.info("[recovery] disabled because SIDEKIQ_RECOVERY_ENABLED!=1") if defined?(Rails)
elsif defined?(Sidekiq)
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
end
