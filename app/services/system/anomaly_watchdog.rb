# frozen_string_literal: true

module System
  class AnomalyWatchdog
    def self.call
      new.call
    end

    def call
      snapshot =
        System::AnomalySnapshot.call

      tracking =
        System::AnomalyStateTracker.call(
          current_snapshot: snapshot
        )

      recovery =
        recover_layer1_stalled(snapshot)

      event =
        System::AnomalyEventSelector.call(
          tracking[:notifyable_events]
        )

      return {
        ok: true,
        notified: false,
        anomalies: snapshot[:anomalies].size,
        recovery: recovery
      } unless event

      message =
        Ollama::AdminAlertFormatter.call(event: event)

      notification =
        {
          message: message,
          severity: event[:severity],
          transition: event[:transition],
          fingerprint: event[:fingerprint],
          generated_at: Time.current
        }

      System::AnomalyBroadcaster.call(
        notification: notification
      )

      {
        ok: true,
        notified: true,
        event: event,
        notification: notification,
        recovery: recovery
      }
    rescue StandardError => error
      Rails.logger.warn(
        "[system_anomaly_watchdog] " \
        "#{error.class}: #{error.message}"
      )

      {
        ok: false,
        notified: false,
        error: "#{error.class}: #{error.message}"
      }
    end

    private

    def recover_layer1_stalled(snapshot)
      stalled =
        Array(snapshot[:anomalies]).any? do |anomaly|
          anomaly[:code].to_s == "layer1_stalled"
        end

      return { attempted: false } unless stalled

      result =
        StrictPipeline::SchedulerWakeup.request!(
          reason: "layer1_stalled_watchdog"
        )

      Rails.logger.warn(
        "[system_anomaly_watchdog] " \
        "layer1_stalled recovery=#{result.inspect}"
      )

      {
        attempted: true,
        result: result
      }
    rescue StandardError => error
      Rails.logger.warn(
        "[system_anomaly_watchdog] " \
        "layer1_stalled_recovery_failed " \
        "#{error.class}: #{error.message}"
      )

      {
        attempted: true,
        error: "#{error.class}: #{error.message}"
      }
    end
  end
end
