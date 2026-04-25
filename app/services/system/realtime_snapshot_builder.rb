# frozen_string_literal: true

module System
  class RealtimeSnapshotBuilder
    WARNING_LAG = 2
    CRITICAL_LAG = 6

    def self.call(now: Time.current)
      new(now: now).call
    end

    def initialize(now:)
      @now = now
    end

    def call
      best_height = BitcoinRpc.new(wallet: nil).getblockcount.to_i

      watcher = ScannerCursor.find_by(name: "zmq_block_watcher")
      processor = ScannerCursor.find_by(name: "realtime_block_stream")

      {
        best_height: best_height,
        watcher: build_cursor_state(watcher, best_height),
        processor: build_cursor_state(processor, best_height)
      }
    rescue StandardError => e
      {
        best_height: nil,
        watcher: { status: :error, error: "#{e.class}: #{e.message}" },
        processor: { status: :error, error: "#{e.class}: #{e.message}" }
      }
    end

    private

    attr_reader :now

    def build_cursor_state(cursor, best_height)
      return { status: :missing, best_height: best_height } if cursor.blank?

      last_height = cursor.last_blockheight.to_i
      lag = last_height.positive? ? best_height - last_height : best_height
      age_seconds = (now - cursor.updated_at).to_i

      {
        status: compute_status(lag),
        last_blockheight: cursor.last_blockheight,
        best_height: best_height,
        lag: lag,
        last_blockhash: cursor.last_blockhash,
        updated_at: cursor.updated_at,
        age_seconds: age_seconds
      }
    end

    def compute_status(lag)
      return :critical if lag >= CRITICAL_LAG
      return :stale if lag >= WARNING_LAG

      :ok
    end
  end
end
