# frozen_string_literal: true

require "test_helper"

module Clusters
  class CompositionRevisionRepairTest < ActiveSupport::TestCase
    test "repairs legacy zero revisions in bounded idempotent batches" do
      legacy =
        Cluster.create!(composition_version: 1)

      with_composition_revision_constraint_removed do
        legacy.update_columns(
          composition_version: 0,
          updated_at: Time.current
        )

        fresh =
          Cluster.create!(composition_version: 2)

        ClusterCompositionRevisionRepairCheckpoint.delete_all
        ClusterCompositionRevisionRepairCheckpoint.create!(
          id: 1,
          status: "pending",
          last_cluster_id: legacy.id - 1
        )

        result =
          Clusters::CompositionRevisionRepair.call(
            batch_size: 1
          )

        assert_equal true, result.fetch(:ok)
        assert_equal 1, result.fetch(:scanned)
        assert_equal 1, result.fetch(:updated)
        assert_equal 1, legacy.reload.composition_version
        assert_equal 2, fresh.reload.composition_version

        second =
          Clusters::CompositionRevisionRepair.call(
            batch_size: 10
          )

        assert_equal true, second.fetch(:ok)
        assert_equal 0, second.fetch(:updated)
        assert_operator second.fetch(:total_scanned), :>=, 2
      end
    end

    private

    def with_composition_revision_constraint_removed
      connection =
        ActiveRecord::Base.connection

      connection.remove_check_constraint(
        :clusters,
        name: "clusters_composition_version_positive",
        if_exists: true
      )

      yield
    ensure
      connection.add_check_constraint(
        :clusters,
        "composition_version >= 1",
        name: "clusters_composition_version_positive",
        validate: false
      )
    end
  end
end
