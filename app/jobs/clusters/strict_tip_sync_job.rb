# frozen_string_literal: true

module Clusters
  class StrictTipSyncJob < ApplicationJob
    queue_as :cluster_strict

    LOCK_NAMESPACE = 41_022
    LOCK_ID = 1
    DEFAULT_LIMIT = 2
    RESCHEDULE_DELAY = 1.second

    def perform(limit: DEFAULT_LIMIT, start_height: nil)
      return locked_result unless acquire_operational_lock

      result = Clusters::StrictTipSyncer.call(limit: limit, start_height: start_height)
      schedule_once(limit: limit, start_height: start_height) if
        Clusters::StrictTipSyncer.work_available?
      result
    ensure
      release_operational_lock if @lock_acquired
    end

    private

    def acquire_operational_lock
      value = ApplicationRecord.connection.select_value(
        "SELECT pg_try_advisory_lock(#{LOCK_NAMESPACE}, #{LOCK_ID})"
      )
      @lock_acquired = value == true || value.to_s == "t"
    end

    def release_operational_lock
      ApplicationRecord.connection.select_value(
        "SELECT pg_advisory_unlock(#{LOCK_NAMESPACE}, #{LOCK_ID})"
      )
      @lock_acquired = false
    end

    def schedule_once(limit:, start_height:)
      self.class.set(wait: RESCHEDULE_DELAY).perform_later(
        limit: limit,
        start_height: start_height
      )
    end

    def locked_result
      { ok: true, status: "skipped", reason: "operational_lock_held" }
    end
  end
end
