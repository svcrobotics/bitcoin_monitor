# frozen_string_literal: true

require "test_helper"

module ActorBehaviors
  module Heavy
    module Service
      class SegmentedDirectDistributionEvidenceTest <
        ActiveSupport::TestCase

        test "uses an independent source first strategy" do
          assert_operator(
            SegmentedDirectDistributionEvidence,
            :<,
            ActorBehaviors::Heavy::
              SegmentedDownstreamDistributionEvidence
          )

          assert_equal(
            "source_first",
            SegmentedDirectDistributionEvidence::
              SCAN_STRATEGY
          )

          assert_equal(
            "service_direct_distribution_segmented_source_first_v2",
            SegmentedDirectDistributionEvidence::
              VERSION
          )
        end

        test "selects source spends before reading all inputs" do
          engine =
            SegmentedDirectDistributionEvidence.new(
              cluster_id:
                34,
              from_height:
                100,
              to_height:
                149,
              chunk_size:
                50
            )

          engine.instance_variable_set(
            :@current_chunk,
            {
              index: 1,
              from_height: 100,
              to_height: 149
            }
          )

          source_sql =
            engine.send(
              :source_spends_sql,
              table:
                '"tmp_source_spends"',
              window:
                100..149
            )

          assert_includes(
            source_sql,
            "source_addresses"
          )

          assert_includes(
            source_sql,
            "CROSS JOIN LATERAL"
          )

          assert_includes(
            source_sql,
            "candidate.address"
          )

          assert_includes(
            source_sql,
            "BETWEEN 100"
          )

          assert_includes(
            source_sql,
            "AND 149"
          )

          refute_includes(
            source_sql,
            "window_inputs"
          )

          all_inputs_sql =
            engine.send(
              :all_input_stats_sql,
              source_spends:
                '"tmp_source_spends"',
              all_input_stats:
                '"tmp_all_input_stats"'
            )

          assert_includes(
            all_inputs_sql,
            'FROM "tmp_source_spends" spend'
          )

          assert_includes(
            all_inputs_sql,
            "input.spent_txid"
          )

          assert_includes(
            all_inputs_sql,
            "input.spent_block_height"
          )

          refute_includes(
            all_inputs_sql,
            "window_inputs"
          )
        end
      end
    end
  end
end
