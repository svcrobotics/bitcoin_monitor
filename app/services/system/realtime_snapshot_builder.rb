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
      processing = Blockchain::State::ProcessingState.new.call

      {
        best_height: best_height,
        watcher: build_cursor_state(watcher, best_height),
        processor: build_layer1_processor_state(processing, best_height)
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
      age_seconds = cursor.updated_at.present? ? (now - cursor.updated_at).to_i : nil

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

    def build_layer1_processor_state(processing, best_height)
      last_height =
        processing[:last_processed_height] ||
        processing["last_processed_height"] ||
        processing[:processed_height] ||
        processing["processed_height"] ||
        last_processed_block&.height

      lag =
        processing[:lag] ||
        processing["lag"] ||
        (last_height.present? ? best_height - last_height.to_i : nil)

      last_processed_block =
        BlockBufferModel
          .where(status: "processed")
          .order(height: :desc)
          .limit(1)
          .first

      updated_at =
        processing[:updated_at] ||
        processing["updated_at"] ||
        processing[:last_processed_at] ||
        processing["last_processed_at"] ||
        last_processed_block&.processed_at ||
        last_processed_block&.updated_at

      age_seconds =
        updated_at.present? ? (now - updated_at.to_time).to_i : nil

      {
        status: compute_status(lag.to_i),
        last_blockheight: last_height,
        best_height: best_height,
        lag: lag,
        last_blockhash: nil,
        updated_at: updated_at,
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