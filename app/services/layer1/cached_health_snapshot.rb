# frozen_string_literal: true

module Layer1
  # Temporary compatibility adapter.
  # New code must use Layer1::Realtime::CachedHealthSnapshot.
  class CachedHealthSnapshot
    def self.read
      Layer1::Realtime::CachedHealthSnapshot.read
    end

    def self.refresh!
      Layer1::Realtime::CachedHealthSnapshot.refresh!
    end
  end
end
