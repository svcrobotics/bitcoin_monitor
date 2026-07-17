# frozen_string_literal: true

require "test_helper"

module Clusters
  class DashboardSnapshotControllerDecisionTest <
    ActiveSupport::TestCase

    test "uses controller authorization when layer1 lag is within backfill threshold" do
      dashboard =
        DashboardSnapshot.call(
          snapshot:
            snapshot(
              layer1_lag: 19,
              cluster_lag: 19
            ),

          decision: {
            allowed: true,
            state: :ready,
            reason: nil,
            failed_constraints: []
          }
        )

      assert_equal(
        "waiting_for_job",
        dashboard.dig(
          :pipeline,
          :state
        )
      )

      assert_equal(
        "Rattrapage en attente de déclenchement",
        dashboard.dig(
          :pipeline,
          :label
        )
      )

      refute_includes(
        dashboard[:status_summary],
        "repasser sous"
      )
    end

    test "describes active layer1 priority without claiming threshold violation" do
      dashboard =
        DashboardSnapshot.call(
          snapshot:
            snapshot(
              layer1_lag: 19,
              cluster_lag: 19
            ),

          decision: {
            allowed: false,
            state: :waiting,
            reason: :layer1_realtime_priority,

            failed_constraints: [
              :layer1_not_processing,
              :strict_io_not_layer1
            ]
          }
        )

      assert_equal(
        "waiting_for_layer1",
        dashboard.dig(
          :pipeline,
          :state
        )
      )

      assert_equal(
        "En attente de Layer1",
        dashboard[:status_label]
      )

      assert_includes(
        dashboard[:status_summary],
        "Layer1 traite actuellement"
      )

      refute_includes(
        dashboard[:status_summary],
        "seuil"
      )
    end

    private

    def snapshot(
      layer1_lag:,
      cluster_lag:
    )
      layer1_tip = 956_772
      cluster_tip =
        layer1_tip -
        cluster_lag

      {
        status: "syncing",

        sync: {
          bitcoin_core_height:
            layer1_tip +
            layer1_lag,

          layer1_tip:
            layer1_tip,

          layer1_status:
            "syncing",

          cluster_tip:
            cluster_tip,

          scanner_lag:
            cluster_lag
        },

        automation: {
          queue_name:
            "cluster_strict",

          process: {
            present: true,
            busy: 0,
            concurrency: 1
          },

          active_workers: 0,
          queue_size: 0,
          scheduled_jobs: 0,
          retry_jobs: 0,
          dead_jobs: 0,
          automation_ok: true
        },

        audit: {
          status: "healthy",
          heights: [],
          counts: {},
          integrity: {}
        },

        coverage: {},
        counts: {},
        activity: {},
        issues: []
      }
    end
  end
end
