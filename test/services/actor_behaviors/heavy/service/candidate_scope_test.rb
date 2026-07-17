# frozen_string_literal: true

require "test_helper"

module ActorBehaviors
  module Heavy
    module Service
      class CandidateScopeTest <
        ActiveSupport::TestCase

        test "selects only the service hypothesis" do
          scope =
            CandidateScope.new(
              limit: 1,
              to_height: 956_941,
              minimum_height_delta: 500
            )

          sql =
            scope.send(
              :sql
            )

          assert_includes(
            sql,
            "service_like_candidate_inputs"
          )

          refute_includes(
            sql,
            "exchange_like_candidate_inputs"
          )

          assert_includes(
            sql,
            "service_score"
          )

          refute_includes(
            sql,
            "exchange_score"
          )

          assert_equal(
            "service_infrastructure",
            CandidateScope::HYPOTHESIS
          )

          assert_equal(
            "heavy_service_candidate_scope_v1",
            CandidateScope::VERSION
          )

          assert_equal(
            true,
            Contract::SHADOW_MODE
          )
        end

        test "joins only the service heavy snapshot" do
          scope =
            CandidateScope.new(
              limit: 1,
              to_height: 956_941,
              minimum_height_delta: 500
            )

          sql =
            scope.send(
              :sql
            )

          assert_includes(
            sql,
            "heavy_snapshot.analysis_kind"
          )

          assert_includes(
            sql,
            "service_infrastructure"
          )

          refute_includes(
            sql,
            "exchange_infrastructure"
          )
        end
      end
    end
  end
end
