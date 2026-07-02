# frozen_string_literal: true

module Layer1
  # Temporary compatibility adapter.
  # New code must use Layer1::Realtime::OperationalSnapshot.
  class OperationalSnapshot
    def self.call
      Layer1::Realtime::OperationalSnapshot.call
    end
  end
end
