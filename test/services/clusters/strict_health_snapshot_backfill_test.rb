# frozen_string_literal: true

require "test_helper"

module Clusters
  class StrictHealthSnapshotBackfillTest <
    ActiveSupport::TestCase

    test "reports warning rather than critical beyond backfill global budget" do
      with_backfill_mode(
        max_global_lag: 30
      ) do
        status =
          service.send(
            :health_status,
            issues: [],
            layer1_status: "syncing",
            cluster_lag: 21,
            cluster_global_lag: 39,
            audit_status: "healthy"
          )

        assert_equal(
          "warning",
          status
        )
      end
    end

    test "reports syncing while recoverable lag remains within budget" do
      with_backfill_mode(
        max_global_lag: 30
      ) do
        status =
          service.send(
            :health_status,
            issues: [],
            layer1_status: "syncing",
            cluster_lag: 12,
            cluster_global_lag: 29,
            audit_status: "healthy"
          )

        assert_equal(
          "syncing",
          status
        )
      end
    end

    test "keeps strict critical threshold outside development backfill" do
      with_pipeline_mode(nil) do
        status =
          service.send(
            :health_status,
            issues: [],
            layer1_status: "syncing",
            cluster_lag: 21,
            cluster_global_lag: 39,
            audit_status: "healthy"
          )

        assert_equal(
          "critical",
          status
        )
      end
    end

    test "real fault remains critical in development backfill" do
      with_backfill_mode(
        max_global_lag: 30
      ) do
        status =
          service.send(
            :health_status,
            issues: [
              "cluster_strict_worker_missing"
            ],
            layer1_status: "syncing",
            cluster_lag: 21,
            cluster_global_lag: 39,
            audit_status: "healthy"
          )

        assert_equal(
          "critical",
          status
        )
      end
    end

    private

    def service
      @service ||=
        StrictHealthSnapshot.new
    end

    def with_backfill_mode(
      max_global_lag:
    )
      previous_lag =
        ENV[
          "TANSA_BACKFILL_MAX_CLUSTER_GLOBAL_LAG"
        ]

      ENV[
        "TANSA_BACKFILL_MAX_CLUSTER_GLOBAL_LAG"
      ] =
        max_global_lag.to_s

      with_pipeline_mode(
        "development_backfill"
      ) do
        yield
      end
    ensure
      ENV[
        "TANSA_BACKFILL_MAX_CLUSTER_GLOBAL_LAG"
      ] =
        previous_lag
    end

    def with_pipeline_mode(mode)
      previous =
        ENV[
          "TANSA_PIPELINE_MODE"
        ]

      if mode.nil?
        ENV.delete(
          "TANSA_PIPELINE_MODE"
        )
      else
        ENV[
          "TANSA_PIPELINE_MODE"
        ] =
          mode
      end

      yield
    ensure
      ENV[
        "TANSA_PIPELINE_MODE"
      ] =
        previous
    end
  end
end
