# frozen_string_literal: true

require "test_helper"

module ActorBehaviors
  module Heavy
    class SegmentedSweepRelationEvidenceTest <
      ActiveSupport::TestCase

      test "splits sweep window without gaps or overlap" do
        windows =
          SegmentedSweepRelationEvidence
            .height_windows(
              from_height:
                953_901,

              to_height:
                956_900,

              chunk_size:
                500
            )

        assert_equal(
          [
            953_901..954_400,
            954_401..954_900,
            954_901..955_400,
            955_401..955_900,
            955_901..956_400,
            956_401..956_900
          ],
          windows
        )

        heights =
          windows.flat_map(
            &:to_a
          )

        assert_equal(
          (953_901..956_900).to_a,
          heights
        )

        assert_equal(
          heights,
          heights.uniq
        )
      end

      test "keeps final partial sweep window" do
        windows =
          SegmentedSweepRelationEvidence
            .height_windows(
              from_height: 1,
              to_height: 1_100,
              chunk_size: 500
            )

        assert_equal(
          [
            1..500,
            501..1_000,
            1_001..1_100
          ],
          windows
        )
      end
    end
  end
end
