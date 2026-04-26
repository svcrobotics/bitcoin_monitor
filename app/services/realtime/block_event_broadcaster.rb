# frozen_string_literal: true

module Realtime
  class BlockEventBroadcaster
    def self.call(height:, blockhash:, created_at: Time.current)
      Turbo::StreamsChannel.broadcast_replace_to(
        "bitcoin_blocks",
        target: "latest_block_live",
        partial: "system/realtime/latest_block",
        locals: {
          block: {
            height: height,
            blockhash: blockhash,
            created_at: created_at
          }
        }
      )
    end
  end
end
