# frozen_string_literal: true

require "test_helper"

module ActorBehaviors
  module Heavy
    class CandidateScopeTest <
      ActiveSupport::TestCase

      test "selects only the exchange hypothesis" do
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
          "exchange_like_candidate_inputs"
        )

        refute_includes(
          sql,
          "service_like_candidate_inputs"
        )

        assert_includes(
          sql,
          "heavy_snapshot.analysis_kind"
        )

        assert_includes(
          sql,
          "exchange_infrastructure"
        )

        assert_equal(
          "exchange_infrastructure",
          CandidateScope::HYPOTHESIS
        )

        assert_equal(
          "heavy_exchange_candidate_scope_v2",
          CandidateScope::VERSION
        )
      end
    end
  end
end
