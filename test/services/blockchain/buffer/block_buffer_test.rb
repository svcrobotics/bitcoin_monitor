# frozen_string_literal: true

require "test_helper"

class Blockchain::Buffer::BlockBufferTest < ActiveSupport::TestCase
  test "heartbeat and final certification preserve timings not supplied again" do
    block = BlockBufferModel.create!(
      height: 999_001,
      block_hash: "0" * 63 + "1",
      status: "processing",
      rpc_duration_ms: 120
    )

    Blockchain::Buffer::BlockBuffer.heartbeat(
      block.height,
      metrics: { parse_duration_ms: 340 }
    )

    block.reload
    assert_equal 120, block.rpc_duration_ms
    assert_equal 340, block.parse_duration_ms

    Blockchain::Buffer::BlockBuffer.mark_processed(
      block.height,
      metrics: { duration_ms: 1_000, flush_duration_ms: 500 }
    )

    block.reload
    assert_equal 120, block.rpc_duration_ms
    assert_equal 340, block.parse_duration_ms
    assert_equal 500, block.flush_duration_ms
    assert_equal 1_000, block.duration_ms
  end
end
