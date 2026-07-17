# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

module ActorProfiles
  class StrictBatchRuntimeBudgetTest <
        ActiveSupport::TestCase
    test "stops before starting another profile after runtime budget" do
      builder =
        ActorProfiles::StrictBatchBuilder.new(
          limit: 3,
          max_runtime_seconds: 0.01
        )

      builder.define_singleton_method(
        :current_cluster_tip
      ) do
        100
      end

      builder.define_singleton_method(
        :current_layer1_tip
      ) do
        100
      end

      builder.define_singleton_method(
        :next_cluster_ids
      ) do
        [11, 12, 13]
      end

      builder.define_singleton_method(
        :missing_profiles_count
      ) do
        0
      end

      builder.define_singleton_method(
        :stale_profiles_count
      ) do
        0
      end

      calls = []

      build =
        lambda do |cluster_id:|
          calls << cluster_id

          sleep 0.02

          {
            ok: true,
            runtime_ms: 20
          }
        end

      ActorProfiles::CertificationEpoch.stub(
        :active?,
        true
      ) do
        ActorProfile.stub(:count, 0) do
          ActorProfiles::
            StrictBuildFromCluster.stub(
              :call,
              build
            ) do
              result = builder.call

              assert_equal(
                [11],
                calls
              )

              assert_equal(
                3,
                result[:selected]
              )

              assert_equal(
                1,
                result[:processed]
              )

              assert_equal(
                1,
                result[:built]
              )

              assert_equal(
                2,
                result[:remaining_selected]
              )

              assert_equal(
                "runtime_budget_exhausted",
                result[:stopped_reason]
              )

              assert result[:ok]
            end
        end
      end
    end
  end
end
