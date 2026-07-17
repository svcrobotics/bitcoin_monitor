# frozen_string_literal: true

require "test_helper"

module Clusters
  class DashboardSnapshotDevelopmentBackfillTest <
    ActiveSupport::TestCase

    test "allows cluster display to catch layer1 within development threshold" do
      with_backfill_mode(
        max_layer1_lag: 20
      ) do
        dashboard =
          DashboardSnapshot.call(
            snapshot:
              snapshot(
                bitcoin_core_height: 120,
                layer1_tip: 100,
                cluster_tip: 95
              )
          )

        assert_equal(
          "waiting_for_job",
          dashboard.dig(
            :pipeline,
            :state
          )
        )

        assert_equal(
          20,
          dashboard.dig(
            :sync,
            :layer1_lag
          )
        )

        assert_equal(
          5,
          dashboard.dig(
            :sync,
            :cluster_lag
          )
        )
      end
    end

    test "waits for layer1 beyond development threshold" do
      with_backfill_mode(
        max_layer1_lag: 20
      ) do
        dashboard =
          DashboardSnapshot.call(
            snapshot:
              snapshot(
                bitcoin_core_height: 121,
                layer1_tip: 100,
                cluster_tip: 95
              )
          )

        assert_equal(
          "waiting_for_layer1",
          dashboard.dig(
            :pipeline,
            :state
          )
        )

        assert_includes(
          dashboard.dig(
            :pipeline,
            :description
          ),
          "20 blocs"
        )
      end
    end

    private

    def snapshot(
      bitcoin_core_height:,
      layer1_tip:,
      cluster_tip:
    )
      {
        status: "syncing",

        sync: {
          bitcoin_core_height:
            bitcoin_core_height,

          layer1_tip:
            layer1_tip,

          layer1_status:
            "syncing",

          cluster_tip:
            cluster_tip,

          scanner_lag:
            layer1_tip -
            cluster_tip
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

    def with_backfill_mode(
      max_layer1_lag:
    )
      previous_mode =
        ENV[
          "TANSA_PIPELINE_MODE"
        ]

      previous_lag =
        ENV[
          "TANSA_BACKFILL_MAX_LAYER1_LAG"
        ]

      ENV[
        "TANSA_PIPELINE_MODE"
      ] =
        "development_backfill"

      ENV[
        "TANSA_BACKFILL_MAX_LAYER1_LAG"
      ] =
        max_layer1_lag.to_s

      yield
    ensure
      ENV[
        "TANSA_PIPELINE_MODE"
      ] =
        previous_mode

      ENV[
        "TANSA_BACKFILL_MAX_LAYER1_LAG"
      ] =
        previous_lag
    end
  end
end
