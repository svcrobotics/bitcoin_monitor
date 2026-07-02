# frozen_string_literal: true

module Layer1
  # Compatibility entry point.
  # New code must use Layer1::Realtime::HealthSnapshot.
  class HealthSnapshot
    def self.call
      Layer1::Realtime::HealthSnapshot.call
    end
  end
end
