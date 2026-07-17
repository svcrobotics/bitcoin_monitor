# frozen_string_literal: true

require "test_helper"

module Layer1
  module Audit
    class OperationalSnapshotTest < ActiveSupport::TestCase
      test "separates latest attempt from highest healthy audited height" do
        latest_run =
          Struct.new(
            :audited_height,
            :status,
            :started_at,
            :finished_at,
            :issues
          ).new(
            956_149,
            "healthy",
            2.seconds.ago,
            1.second.ago,
            []
          )

        snapshot = OperationalSnapshot.new

        snapshot.define_singleton_method(:latest_attempt) do
          latest_run
        end

        snapshot.define_singleton_method(:latest_healthy_attempt) do
          latest_run
        end

        snapshot.define_singleton_method(:highest_healthy_height) do
          956_249
        end

        snapshot.define_singleton_method(:realtime_tip) do
          956_249
        end

        snapshot.define_singleton_method(:queue_snapshot) do
          {
            name: "layer1_audit",
            size: 0,
            latency_seconds: 0.0
          }
        end

        snapshot.define_singleton_method(:busy_workers) do
          0
        end

        snapshot.define_singleton_method(:recent_runs_summary) do
          {
            sample_size: 2,
            healthy: 2,
            failed: 0,
            errors: 0,
            running: 0
          }
        end

        result = snapshot.call

        assert_equal "healthy", result[:status]
        assert_equal "idle", result[:activity]
        assert_equal 956_249, result[:realtime_tip]

        assert_equal 956_149, result[:last_attempted_height]
        assert_equal 956_149, result[:last_healthy_height]
        assert_equal 956_249, result[:highest_healthy_height]

        assert_equal 100, result[:last_healthy_lag]
        assert_equal 0, result[:highest_healthy_lag]

        assert_equal 956_149, result.dig(:last_run, :audited_height)
        assert_equal 956_149, result.dig(:last_healthy_run, :audited_height)
      end
    end
  end
end
