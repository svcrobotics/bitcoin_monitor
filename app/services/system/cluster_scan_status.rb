# frozen_string_literal: true

module System
  class ClusterScanStatus
    WARNING_LAG = 12
    CRITICAL_LAG = 48

    def self.call
      new.call
    end

    def call
      rpc = BitcoinRpc.new(wallet: nil)

      best_height = rpc.getblockcount.to_i

      cursor = ScannerCursor.find_by(name: "cluster_scan")

      last_height = cursor&.last_blockheight.to_i

      lag =
        if last_height.positive?
          best_height - last_height
        else
          best_height
        end

      {
        cursor_height: last_height,
        best_height: best_height,
        lag: lag,
        status: compute_status(lag)
      }
    rescue StandardError => e
      {
        cursor_height: nil,
        best_height: nil,
        lag: nil,
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
