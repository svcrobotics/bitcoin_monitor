# frozen_string_literal: true

class SystemSnapshotsRefreshJob < ApplicationJob
  queue_as :low

  def perform
    System::Snapshots::TablesHealthCapture.call
    System::Snapshots::ClusterPipelineStatusCapture.call
    System::Snapshots::HealthSnapshotCapture.call

    SystemSnapshot.prune!(keep: 20)
  end
end