# frozen_string_literal: true

module Clusters
  class HealthSnapshotRefreshJob
    include Sidekiq::Job

    sidekiq_options queue: :low, retry: false

    def perform
      Clusters::CachedHealthSnapshot.refresh!
    end
  end
end
