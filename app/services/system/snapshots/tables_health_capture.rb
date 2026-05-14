module System
  module Snapshots
    class TablesHealthCapture
      def self.call
        new.call
      end

      def call
        payload = SystemController.new.send(:build_tables_health)

        SystemSnapshot.capture!(
          "tables_health",
          payload
        )
      end
    end
  end
end