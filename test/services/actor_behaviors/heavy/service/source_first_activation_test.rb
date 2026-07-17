# frozen_string_literal: true

require "test_helper"

module ActorBehaviors
  module Heavy
    module Service
      class SourceFirstActivationTest <
        ActiveSupport::TestCase

        test "uses the source first engine by default" do
          assert_equal(
            SegmentedDirectDistributionEvidence,
            DirectDistributionEvidence::ENGINE
          )

          refute_equal(
            ActorBehaviors::Heavy::
              SegmentedDownstreamDistributionEvidence,
            DirectDistributionEvidence::ENGINE
          )

          assert_equal(
            "source_first",
            DirectDistributionEvidence::
              ENGINE::
              SCAN_STRATEGY
          )

          assert_equal(
            "service_direct_distribution_segmented_source_first_v2",
            DirectDistributionEvidence::
              ENGINE::
              VERSION
          )
        end

        test "invalidates service v1 snapshots" do
          assert_equal(
            "service_infrastructure_heavy_shadow_v2",
            Contract::HEAVY_VERSION
          )

          scope =
            CandidateScope.new(
              limit:
                1,

              to_height:
                957_008,

              minimum_height_delta:
                500
            )

          sql =
            scope.send(
              :sql
            )

          assert_includes(
            sql,
            "service_infrastructure_heavy_shadow_v2"
          )

          refute_includes(
            sql,
            "service_infrastructure_heavy_shadow_v1"
          )
        end
      end
    end
  end
end
