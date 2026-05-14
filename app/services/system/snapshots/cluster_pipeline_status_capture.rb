module System
  module Snapshots
    class ClusterPipelineStatusCapture
      def self.call
        new.call
      end

      def call
        payload = System::ClusterPipelineStatus.call

        SystemSnapshot.capture!(
          "cluster_pipeline_status",
          payload
        )
      end
    end
  end
end