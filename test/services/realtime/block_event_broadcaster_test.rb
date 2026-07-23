# frozen_string_literal: true

require "test_helper"

module Realtime
  class BlockEventBroadcasterTest < ActiveSupport::TestCase
    include ActionCable::TestHelper

    test "broadcasts a rendered replacement for the latest block" do
      assert_broadcasts("bitcoin_blocks", 1) do
        BlockEventBroadcaster.call(
          height: 956_321,
          blockhash: "0000000000000000000123456789abcdef",
          created_at: Time.zone.parse("2026-07-23 14:05:06")
        )
      end
    end
  end
end
