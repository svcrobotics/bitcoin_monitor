# frozen_string_literal: true

module Layer1
  # Temporary compatibility adapter.
  # New code must use Layer1::Realtime::RecentBlockCadenceSnapshot.
  class RecentBlockCadenceSnapshot
    def self.call(**kwargs)
      Layer1::Realtime::RecentBlockCadenceSnapshot.call(**kwargs)
    end
  end
end
