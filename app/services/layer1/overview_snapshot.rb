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
        historical_projection: historical_projection_snapshot(realtime)
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

      Layer1::TxOutputsSpentSync::OperationalSnapshot.call(
        processed_height: processed_height(realtime_snapshot)
      )
    rescue StandardError => error
      Rails.logger.error(
        "[layer1_overview_snapshot] historical_projection_error " \
        "#{error.class}: #{error.message}"
      )

      {
        status: "unavailable",
        enabled: true,
        error: "#{error.class}: #{error.message}"
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
        status: "critical",
        activity: "unavailable",
        error: "#{error.class}: #{error.message}"
      }
    end

    def processed_height(snapshot)
      return nil unless snapshot.respond_to?(:[])

      sync = snapshot[:sync] || snapshot["sync"] || {}

      snapshot[:processed_height] ||
        snapshot["processed_height"] ||
        sync[:processed_height] ||
        sync["processed_height"]
    end
  end
end
