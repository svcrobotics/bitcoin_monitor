# frozen_string_literal: true

if defined?(Sidekiq)
  Sidekiq.configure_server do |config|
    config.on(:startup) do
      next unless ENV[
        "CLUSTER_COVERAGE_WORKER"
      ] == "1"

      begin
        acquired =
          Sidekiq.redis do |redis|
            redis.set(
              "cluster_coverage:maintenance:startup",
              Process.pid,
              nx: true,
              ex: 60
            )
          end

        unless acquired
          Rails.logger.info(
            "[cluster_coverage_startup] " \
            "enqueue skipped: startup lock present"
          )

          next
        end

        Rails.logger.info(
          "[cluster_coverage_startup] " \
          "enqueue maintenance"
        )

        Clusters::Coverage::MaintenanceJob
          .perform_later(
            {
              "reschedule" => true,
              "lock" => true
            }
          )
      rescue StandardError => error
        Rails.logger.error(
          "[cluster_coverage_startup] " \
          "enqueue failed " \
          "#{error.class}: #{error.message}"
        )
      end
    end
  end
end
