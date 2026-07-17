# frozen_string_literal: true

require "test_helper"

module Layer1
  module Realtime
    class HealthSnapshotBoundaryTest < ActiveSupport::TestCase
      test "does not perform global scans on large Layer1 tables" do
        source =
          File.read(
            Rails.root.join(
              "app/services/layer1/realtime/health_snapshot.rb"
            )
          )

        refute_includes source, "UtxoOutput.count"
        refute_includes source, "ClusterInput.count"

        refute_includes(
          source,
          "UtxoOutput.maximum(:created_at)"
        )

        refute_includes(
          source,
          "ClusterInput.maximum(:created_at)"
        )

        assert_includes(
          source,
          'estimated_table_count("utxo_outputs")'
        )

        assert_includes(
          source,
          'estimated_table_count("cluster_inputs")'
        )

        assert_includes(
          source,
          "latest_created_at(UtxoOutput)"
        )

        assert_includes(
          source,
          "latest_created_at(ClusterInput)"
        )
      end
    end
  end
end
