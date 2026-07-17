# frozen_string_literal: true

require "test_helper"

module Layer1
  class DashboardSnapshotOverviewTest <
    ActiveSupport::TestCase

    test "builds dashboard from overview snapshot" do
      overview = {
        source:
          "layer1_overview_snapshot",

        generated_at:
          Time.current,

        realtime: {
          status:
            "warning",

          bitcoin_core_height:
            120,

          processed_height:
            100,

          lag:
            20,

          buffers: {
            outputs: 0,
            spent: 0
          },

          activity: {
            pipeline_state:
              "active"
          },

          strict: {
            worker: {
              present: true,
              busy: 1,
              pid: 123
            },

            scheduler: {
              registered: true,
              enabled: true,
              status: "enabled"
            },

            scheduler_process: {
              present: true
            },

            queue_size: 0,
            scheduled_jobs: 0,
            processing_block: nil
          },

          counts: {
            block_buffers: 100,
            utxo_outputs: 200,
            cluster_inputs: 300
          },

          cursors: {},
          timestamps: {},
          queues: {}
        },

        audit: {
          status: "healthy",
          activity: "idle",
          last_healthy_height: 99
        },

        pace: {
          status: "available",

          comparison: {
            trend: "stable"
          }
        },

        historical_projection: {
          status: "pending",
          enabled: true,

          outputs: {
            status: "deferred",
            enabled: true,
            pending_count: 12,
            failed_count: 0,
            last_synced_height: 90,
            projection_lag_blocks: 10,

            worker: {
              present: true,
              busy: 0
            }
          },

          spent_sync: {
            status: "deferred",
            enabled: true,
            pending_count: 8,
            failed_count: 0,
            last_synced_height: 92,
            projection_lag_blocks: 8,

            worker: {
              present: true,
              busy: 0
            }
          }
        }
      }

      service =
        DashboardSnapshot.new(
          snapshot: overview
        )

      service.define_singleton_method(
        :recent_processed_rows
      ) do
        []
      end

      service.define_singleton_method(
        :proof_snapshot
      ) do
        {
          total_checks: 0,
          passed_checks: 0,
          compliance: nil,
          conformant: false
        }
      end

      dashboard =
        service.call

      assert_equal(
        120,
        dashboard.dig(
          :sync,
          :bitcoin_core_height
        )
      )

      assert_equal(
        100,
        dashboard.dig(
          :sync,
          :processed_height
        )
      )

      assert_equal(
        "healthy",
        dashboard.dig(
          :audit,
          :status
        )
      )

      assert_equal(
        "stable",
        dashboard.dig(
          :pace,
          :comparison,
          :trend
        )
      )

      projection =
        dashboard[
          :historical_projection
        ]

      assert_equal(
        "deferred",
        projection[:state]
      )

      assert_equal(
        20,
        projection[:pending_count]
      )

      assert_equal(
        10,
        projection[:projection_lag_blocks]
      )

      assert_equal(
        12,
        projection.dig(
          :outputs,
          :pending_count
        )
      )

      assert_equal(
        8,
        projection.dig(
          :spent_sync,
          :pending_count
        )
      )

      assert_equal(
        "layer1_dashboard_snapshot",
        dashboard[:source]
      )
    end
  end
end
