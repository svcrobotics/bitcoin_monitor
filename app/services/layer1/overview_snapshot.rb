# frozen_string_literal: true

module Layer1
  class OverviewSnapshot
    def self.call(realtime: nil, historical_projection: nil)
      new(
        realtime: realtime,
        historical_projection: historical_projection
      ).call
    end

    def initialize(realtime: nil, historical_projection: nil)
      @realtime = realtime
      @historical_projection = historical_projection
    end

    def call
      realtime = realtime_snapshot

      {
        source: "layer1_overview_snapshot",
        generated_at: Time.current,
        realtime: realtime,
        audit: audit_snapshot,
        historical_projection: historical_projection_snapshot(realtime),
        pace: pace_snapshot(realtime)
      }
    end

    private

    attr_reader :realtime, :historical_projection

    def realtime_snapshot
      realtime.presence ||
        Layer1::Realtime::HealthSnapshot.call
    rescue StandardError => error
      Rails.logger.error(
        "[layer1_overview_snapshot] realtime_error " \
        "#{error.class}: #{error.message}"
      )

      {
        status: "critical",
        error: "#{error.class}: #{error.message}"
      }
    end

    def historical_projection_snapshot(realtime_snapshot)
      return historical_projection if historical_projection.present?

      processed_height = processed_height(realtime_snapshot)
      outputs =
        tx_output_projection_snapshot(processed_height: processed_height)
      spent_sync =
        tx_outputs_spent_sync_snapshot(processed_height: processed_height)

      {
        status: historical_projection_status(outputs, spent_sync),
        enabled: true,
        outputs: outputs,
        spent_sync: spent_sync
      }
    end

    def audit_snapshot
      Layer1::Audit::OperationalSnapshot.call
    rescue StandardError => error
      Rails.logger.error(
        "[layer1_overview_snapshot] audit_error " \
        "#{error.class}: #{error.message}"
      )

      {
        status: "unavailable",
        activity: "unavailable",
        error: "#{error.class}: #{error.message}"
      }
    end

    def pace_snapshot(realtime_snapshot)
      Layer1::PaceSnapshot.call(
        current_lag: realtime_lag(realtime_snapshot)
      )
    rescue StandardError => error
      Rails.logger.error(
        "[layer1_overview_snapshot] pace_error " \
        "#{error.class}: #{error.message}"
      )

      {
        status: "unavailable",
        error: "#{error.class}: #{error.message}",
        comparison: {
          trend: "insufficient_data"
        }
      }
    end

    def tx_output_projection_snapshot(processed_height:)
      Layer1::TxOutputProjection::OperationalSnapshot.call(
        processed_height: processed_height
      )
    rescue StandardError => error
      Rails.logger.error(
        "[layer1_overview_snapshot] tx_output_projection_error " \
        "#{error.class}: #{error.message}"
      )

      {
        status: "unavailable",
        enabled: true,
        error: "#{error.class}: #{error.message}"
      }
    end

    def tx_outputs_spent_sync_snapshot(processed_height:)
      Layer1::TxOutputsSpentSync::OperationalSnapshot.call(
        processed_height: processed_height
      )
    rescue StandardError => error
      Rails.logger.error(
        "[layer1_overview_snapshot] tx_outputs_spent_sync_error " \
        "#{error.class}: #{error.message}"
      )

      {
        status: "unavailable",
        enabled: true,
        error: "#{error.class}: #{error.message}"
      }
    end

    def historical_projection_status(outputs, spent_sync)
      statuses =
        [
          status_value(outputs),
          status_value(spent_sync)
        ].compact

      return "unavailable" if statuses.include?("unavailable")
      return "failed" if statuses.include?("failed")
      return "processing" if statuses.include?("processing")
      return "pending" if (statuses & %w[pending behind deferred]).any?
      return "synced" if statuses.include?("synced")
      return "disabled" if statuses.all? { |status| status == "disabled" }

      statuses.first || "unavailable"
    end

    def status_value(snapshot)
      return nil unless snapshot.respond_to?(:[])

      snapshot[:status] || snapshot["status"]
    end

    def processed_height(snapshot)
      return nil unless snapshot.respond_to?(:[])

      sync = snapshot[:sync] || snapshot["sync"] || {}

      snapshot[:processed_height] ||
        snapshot["processed_height"] ||
        sync[:processed_height] ||
        sync["processed_height"]
    end

    def realtime_lag(snapshot)
      sync = snapshot[:sync] || snapshot["sync"] || {}

      snapshot[:lag] ||
        snapshot["lag"] ||
        sync[:lag] ||
        sync["lag"]
    end
  end
end
