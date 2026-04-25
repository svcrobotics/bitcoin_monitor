# frozen_string_literal: true

module System
  class RealtimeSnapshotBuilder
    STALE_AFTER = 20.minutes

    def self.call(now: Time.current)
      new(now: now).call
    end

    def initialize(now:)
      @now = now
    end

    def call
      watcher = ScannerCursor.find_by(name: "zmq_block_watcher")
      processor = ScannerCursor.find_by(name: "realtime_block_stream")

      {
        watcher: build_cursor_state(watcher),
        processor: build_cursor_state(processor)
      }
    end

    private

    attr_reader :now

    def build_cursor_state(cursor)
      return { status: :missing } if cursor.blank?

      age_seconds = (now - cursor.updated_at).to_i

      {
        status: age_seconds <= STALE_AFTER ? :ok : :stale,
        last_blockheight: cursor.last_blockheight,
        last_blockhash: cursor.last_blockhash,
        updated_at: cursor.updated_at,
        age_seconds: age_seconds
      }
    end
  end
end
