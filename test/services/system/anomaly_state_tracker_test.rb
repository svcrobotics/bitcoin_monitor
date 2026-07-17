# frozen_string_literal: true

require "test_helper"

module System
  class AnomalyStateTrackerTest < ActiveSupport::TestCase
    setup do
      Sidekiq.redis { |redis| redis.del(System::AnomalyStateTracker::STATE_KEY) }
    end

    test "emits a new notification once for a new anomaly" do
      first =
        System::AnomalyStateTracker.call(
          current_snapshot: snapshot_with(anomaly)
        )

      second =
        System::AnomalyStateTracker.call(
          current_snapshot: snapshot_with(anomaly)
        )

      assert_equal ["new"], first[:notifyable_events].map { |e| e[:transition] }
      assert_empty second[:notifyable_events]
    end

    test "emits worsening when the primary metric grows significantly" do
      System::AnomalyStateTracker.call(
        current_snapshot: snapshot_with(anomaly(lag: 5))
      )

      result =
        System::AnomalyStateTracker.call(
          current_snapshot: snapshot_with(anomaly(lag: 14))
        )

      assert_equal ["worsened"], result[:notifyable_events].map { |e| e[:transition] }
    end

    test "emits resolved when an active anomaly disappears" do
      System::AnomalyStateTracker.call(
        current_snapshot: snapshot_with(anomaly)
      )

      result =
        System::AnomalyStateTracker.call(
          current_snapshot: snapshot_with(nil)
        )

      assert_equal ["resolved"], result[:notifyable_events].map { |e| e[:transition] }
    end

    test "requires consecutive observations when requested" do
      delayed =
        anomaly.merge(
          confirmation_observations: 2
        )

      first =
        System::AnomalyStateTracker.call(
          current_snapshot: snapshot_with(delayed)
        )

      second =
        System::AnomalyStateTracker.call(
          current_snapshot: snapshot_with(delayed)
        )

      assert_empty first[:notifyable_events]
      assert_equal ["new"], second[:notifyable_events].map { |e| e[:transition] }
    end

    private

    def snapshot_with(anomaly)
      {
        generated_at: Time.current,
        overall_severity: anomaly ? anomaly[:severity] : nil,
        anomalies: anomaly ? [anomaly] : []
      }
    end

    def anomaly(lag: 5)
      {
        code: "layer1_lag_critical",
        module: "layer1",
        severity: "critical",
        title: "Layer1 a un retard critique",
        facts: {
          lag_blocks: lag
        },
        fingerprint: "layer1:lag_critical",
        confirmation_observations: 1
      }
    end
  end
end
