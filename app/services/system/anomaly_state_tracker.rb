# frozen_string_literal: true

require "json"

module System
  class AnomalyStateTracker
    STATE_KEY = "system:anomalies:state:v1"
    STATE_TTL_SECONDS = 7.days.to_i

    SEVERITY_RANK = {
      "warning" => 1,
      "critical" => 2
    }.freeze

    def self.call(current_snapshot:, now: Time.current)
      new(
        current_snapshot: current_snapshot,
        now: now
      ).call
    end

    def initialize(current_snapshot:, now:)
      @current_snapshot = current_snapshot || {}
      @now = now
    end

    def call
      previous =
        read_state

      current_anomalies =
        Array(current_snapshot[:anomalies])

      current_by_fingerprint =
        current_anomalies.index_by { |anomaly| anomaly[:fingerprint].to_s }

      events =
        current_anomalies.map do |anomaly|
          observe_active(anomaly, previous[anomaly[:fingerprint].to_s])
        end

      resolved =
        previous
          .values
          .select { |state| state["active"] == true }
          .reject do |state|
            current_by_fingerprint.key?(state["fingerprint"].to_s)
          end
          .map do |state|
            observe_resolved(state)
          end

      events.concat(resolved)

      write_state(previous)

      {
        generated_at: now,
        events: events,
        notifyable_events:
          events.select { |event| event[:notify] == true }
      }
    rescue StandardError => error
      Rails.logger.warn(
        "[system_anomaly_tracker] #{error.class}: #{error.message}"
      )

      {
        generated_at: now,
        events: [],
        notifyable_events: []
      }
    end

    private

    attr_reader :current_snapshot, :now

    def observe_active(anomaly, previous)
      fingerprint =
        anomaly[:fingerprint].to_s

      metric =
        primary_metric(anomaly[:facts] || {})

      if previous.blank? || previous["active"] != true
        state =
          {
            "fingerprint" => fingerprint,
            "active" => true,
            "first_detected_at" => now.iso8601(6),
            "last_observed_at" => now.iso8601(6),
            "consecutive_observations" => 1,
            "severity" => anomaly[:severity].to_s,
            "facts" => anomaly[:facts] || {},
            "last_notified_at" => nil,
            "last_notified_metric" => nil
          }

        update_state(fingerprint, state)

        return event_for(
          transition: "new",
          anomaly: anomaly,
          state: state,
          notify: confirmed?(anomaly, state)
        )
      end

      previous["last_observed_at"] =
        now.iso8601(6)
      previous["consecutive_observations"] =
        previous["consecutive_observations"].to_i + 1

      worsened =
        severity_worsened?(anomaly, previous) ||
        metric_worsened?(metric, previous["last_notified_metric"])

      previous["severity"] =
        anomaly[:severity].to_s
      previous["facts"] =
        anomaly[:facts] || {}

      transition =
        if previous["last_notified_at"].blank? &&
           confirmed?(anomaly, previous)
          "new"
        elsif worsened
          "worsened"
        else
          "unchanged"
        end

      notify =
        %w[new worsened].include?(transition)

      event =
        event_for(
          transition: transition,
          anomaly: anomaly,
          state: previous,
          notify: notify
        )

      update_state(fingerprint, previous)

      event
    end

    def observe_resolved(state)
      state["active"] =
        false
      state["resolved_at"] =
        now.iso8601(6)
      state["last_observed_at"] =
        now.iso8601(6)

      update_state(state["fingerprint"], state)

      {
        transition: "resolved",
        code: state.dig("anomaly", "code") || state["code"],
        module: state.dig("anomaly", "module") || state["module"],
        severity: state["severity"],
        title: "Anomalie résolue",
        facts: state["facts"] || {},
        fingerprint: state["fingerprint"],
        first_detected_at: parse_time(state["first_detected_at"]),
        notify: true
      }
    end

    def event_for(transition:, anomaly:, state:, notify:)
      if notify
        state["last_notified_at"] =
          now.iso8601(6)
        state["last_notified_metric"] =
          primary_metric(anomaly[:facts] || {})
      end

      state["code"] =
        anomaly[:code].to_s
      state["module"] =
        anomaly[:module].to_s
      state["anomaly"] =
        anomaly

      {
        transition: transition,
        code: anomaly[:code].to_s,
        module: anomaly[:module].to_s,
        severity: anomaly[:severity].to_s,
        title: anomaly[:title].to_s,
        facts: anomaly[:facts] || {},
        fingerprint: anomaly[:fingerprint].to_s,
        first_detected_at:
          parse_time(state["first_detected_at"]),
        consecutive_observations:
          state["consecutive_observations"].to_i,
        notify: notify
      }
    end

    def confirmed?(anomaly, state)
      state["consecutive_observations"].to_i >=
        anomaly[:confirmation_observations].to_i.clamp(1, 10)
    end

    def severity_worsened?(anomaly, previous)
      SEVERITY_RANK.fetch(anomaly[:severity].to_s, 0) >
        SEVERITY_RANK.fetch(previous["severity"].to_s, 0)
    end

    def metric_worsened?(current, previous)
      return false if current.nil? || previous.nil?

      current =
        current.to_f
      previous =
        previous.to_f

      return current >= previous + 5 if previous < 10

      current >= previous * 1.5
    end

    def primary_metric(facts)
      facts.each_value do |value|
        return value if value.is_a?(Numeric)
      end

      nil
    end

    def read_state
      raw =
        Sidekiq.redis do |redis|
          redis.get(STATE_KEY)
        end

      raw.present? ? JSON.parse(raw) : {}
    rescue StandardError
      {}
    end

    def update_state(fingerprint, state)
      @next_state ||= read_state
      @next_state[fingerprint.to_s] = state
    end

    def write_state(previous)
      state =
        @next_state || previous

      Sidekiq.redis do |redis|
        redis.set(
          STATE_KEY,
          JSON.generate(state),
          ex: STATE_TTL_SECONDS
        )
      end
    rescue StandardError => error
      Rails.logger.warn(
        "[system_anomaly_tracker] state_write_failed " \
        "#{error.class}: #{error.message}"
      )
    end

    def parse_time(value)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
