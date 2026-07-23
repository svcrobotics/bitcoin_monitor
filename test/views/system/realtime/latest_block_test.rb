# frozen_string_literal: true

require "test_helper"

class SystemRealtimeLatestBlockTest < ActionView::TestCase
  test "renders the latest received block" do
    received_at = Time.zone.parse("2026-07-23 14:05:06")
    blockhash = "0000000000000000000123456789abcdef"

    render(
      partial: "system/realtime/latest_block",
      locals: {
        block: {
          height: 956_321,
          blockhash: blockhash,
          created_at: received_at
        }
      }
    )

    assert_select "#latest_block_live"
    assert_includes rendered, "956 321"
    assert_includes rendered, "00000000000000…"
    assert_select "[title='#{blockhash}']"
    assert_select "time[datetime='#{received_at.iso8601}']", text: /14:05:06/
  end
end
