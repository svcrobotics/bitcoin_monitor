# frozen_string_literal: true

module System
  class ClusterScanStatus
    WARNING_LAG = 3
    CRITICAL_LAG = 12

    CURSOR_NAME = "realtime_block_stream"

    def self.call
      new.call
    end

    def call
      rpc = BitcoinRpc.new(wallet: nil)
      best_height = rpc.getblockcount.to_i

      cursor = ScannerCursor.find_by(name: CURSOR_NAME)
      last_height = cursor&.last_blockheight.to_i

      lag =
        if last_height.positive?
          best_height - last_height
        else
          best_height
        end

      {
        label: "Cluster realtime",
        cursor_name: CURSOR_NAME,
        cursor_height: last_height,
        best_height: best_height,
        lag: lag,
        updated_at: cursor&.updated_at,
        last_blockhash: cursor&.last_blockhash,
        status: compute_status(lag)
      }
    rescue StandardError => e
      {
        label: "Cluster realtime",
        cursor_name: CURSOR_NAME,
        cursor_height: nil,
        best_height: nil,
        lag: nil,
        updated_at: nil,
        last_blockhash: nil,
        status: "error",
        error: "#{e.class}: #{e.message}"
      }
    end

    private

    def compute_status(lag)
      return "critical" if lag >= CRITICAL_LAG
      return "warning" if lag >= WARNING_LAG

      "ok"
    end
  end
end