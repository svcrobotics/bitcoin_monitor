module System
  module Snapshots
    class HealthSnapshotCapture
      def self.call
        new.call
      end

      def call
        payload = System::HealthSnapshotBuilder.call

        SystemSnapshot.capture!(
          "health_snapshot",
          payload
        )
      end
    end
  end
end