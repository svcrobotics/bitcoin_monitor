# frozen_string_literal: true

module System
  class AnomalyBroadcaster
    STREAM = "system_anomalies"
    TARGET = "system_anomaly_notification"

    def self.call(notification:)
      new(notification: notification).call
    end

    def initialize(notification:)
      @notification = notification
    end

    def call
      Turbo::StreamsChannel.broadcast_replace_to(
        STREAM,
        target: TARGET,
        partial: "system/anomaly_notification",
        locals: {
          notification: notification
        }
      )
    rescue StandardError => error
      Rails.logger.warn(
        "[system_anomaly_broadcaster] " \
        "#{error.class}: #{error.message}"
      )

      false
    end

    private

    attr_reader :notification
  end
end
