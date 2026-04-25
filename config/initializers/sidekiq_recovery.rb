# frozen_string_literal: true

if defined?(Sidekiq)
  Sidekiq.configure_server do |config|
    config.on(:startup) do
      Rails.logger.info("[recovery] startup enqueue")

      begin
        RecoveryOrchestratorJob.perform_later
      rescue => e
        Rails.logger.error("[recovery] startup enqueue failed #{e.class} #{e.message}")
      end
    end
  end
end
