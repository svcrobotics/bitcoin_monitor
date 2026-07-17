# frozen_string_literal: true

require "test_helper"

module ActorBehaviors
  module Heavy
    class SegmentedDownstreamDistributionEvidenceTest <
      ActiveSupport::TestCase

      test "splits an inclusive height window without overlap" do
        windows =
          SegmentedDownstreamDistributionEvidence
            .height_windows(
              from_height: 401,
              to_height: 900,
              chunk_size: 100
            )

        assert_equal(
          [
            401..500,
            501..600,
            601..700,
            701..800,
            801..900
          ],
          windows
        )

        heights =
          windows.flat_map(&:to_a)

        assert_equal(
          (401..900).to_a,
          heights
        )

        assert_equal(
          heights.uniq,
          heights
        )
      end

      test "keeps a final partial window" do
        windows =
          SegmentedDownstreamDistributionEvidence
            .height_windows(
              from_height: 10,
              to_height: 265,
              chunk_size: 100
            )

        assert_equal(
          [
            10..109,
            110..209,
            210..265
          ],
          windows
        )
      end
    end
  end
end
