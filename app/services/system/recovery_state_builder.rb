# frozen_string_literal: true

module System
  class RecoveryStateBuilder
    REALTIME_WARNING_LAG = 2
    REALTIME_STALLED_LAG = 12

    CLUSTER_WARNING_LAG = 12
    CLUSTER_STALLED_LAG = 96

    EXCHANGE_WARNING_LAG = 6
    EXCHANGE_STALLED_LAG = 48

    def self.call
      new.call
    end

    def call
      best_height = BitcoinRpc.new(wallet: nil).getblockcount.to_i

      realtime_lag = cursor_lag("realtime_block_stream", best_height)
      cluster_lag  = cursor_lag("cluster_scan", best_height)
      exchange_lag = cursor_lag("exchange_observed_scan", best_height)

      state = compute_state(
        realtime_lag: realtime_lag,
        cluster_lag: cluster_lag,
        exchange_lag: exchange_lag
      )

      {
        state: state,
        best_height: best_height,
        realtime_lag: realtime_lag,
        cluster_lag: cluster_lag,
        exchange_lag: exchange_lag,
        recovering: state == "catching_up",
        degraded: state == "degraded",
        stalled: state == "stalled"
      }
    rescue StandardError => e
      {
        state: "error",
        error: "#{e.class}: #{e.message}"
      }
    end

    private

    def cursor_lag(name, best_height)
      cursor = ScannerCursor.find_by(name: name)
      height = cursor&.last_blockheight.to_i

      height.positive? ? best_height - height : best_height
    end

    def compute_state(realtime_lag:, cluster_lag:, exchange_lag:)
      return "stalled" if realtime_lag >= REALTIME_STALLED_LAG
      return "stalled" if cluster_lag >= CLUSTER_STALLED_LAG
      return "stalled" if exchange_lag >= EXCHANGE_STALLED_LAG

      return "degraded" if realtime_lag >= REALTIME_WARNING_LAG
      return "catching_up" if cluster_lag >= CLUSTER_WARNING_LAG
      return "catching_up" if exchange_lag >= EXCHANGE_WARNING_LAG

      "healthy"
    end
  end
end
