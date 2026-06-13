# frozen_string_literal: true

module Layer1
  class HealthSnapshotRefreshJob
    include Sidekiq::Job

    sidekiq_options queue: :low, retry: false

    def perform
      Layer1::CachedHealthSnapshot.refresh!
    end
  end
end
