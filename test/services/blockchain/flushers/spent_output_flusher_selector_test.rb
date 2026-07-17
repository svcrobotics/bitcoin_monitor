# frozen_string_literal: true

require "test_helper"

class SpentOutputFlusherSelectorTest < ActiveSupport::TestCase
  setup do
    @previous_value = ENV["SPENT_OUTPUT_FLUSHER_V2"]
  end

  teardown do
    if @previous_value.nil?
      ENV.delete("SPENT_OUTPUT_FLUSHER_V2")
    else
      ENV["SPENT_OUTPUT_FLUSHER_V2"] = @previous_value
    end
  end

  test "selects v2 when enabled" do
    ENV["SPENT_OUTPUT_FLUSHER_V2"] = "1"

    assert_equal(
      Blockchain::Flushers::SpentOutputFlusherV2,
      Blockchain::Flushers::SpentOutputFlusherSelector.flusher_class
    )
  end

  test "keeps legacy flusher when v2 is disabled" do
    ENV["SPENT_OUTPUT_FLUSHER_V2"] = "0"

    assert_equal(
      Blockchain::Flushers::SpentOutputFlusher,
      Blockchain::Flushers::SpentOutputFlusherSelector.flusher_class
    )
  end

  test "passes recovery mode by default" do
    ENV["SPENT_OUTPUT_FLUSHER_V2"] = "1"

    flusher =
      Blockchain::Flushers::SpentOutputFlusherSelector.build(
        redis: Object.new
      )

    assert_equal :recovery, flusher.mode
  end

  test "passes explicit realtime mode" do
    ENV["SPENT_OUTPUT_FLUSHER_V2"] = "1"

    flusher =
      Blockchain::Flushers::SpentOutputFlusherSelector.build(
        redis: Object.new,
        mode: :realtime
      )

    assert_equal :realtime, flusher.mode
  end

  test "rejects invalid mode" do
    error =
      assert_raises(ArgumentError) do
        Blockchain::Flushers::SpentOutputFlusherSelector.build(
          redis: Object.new,
          mode: :invalid
        )
      end

    assert_match "unknown spent output flusher mode", error.message
  end
end
