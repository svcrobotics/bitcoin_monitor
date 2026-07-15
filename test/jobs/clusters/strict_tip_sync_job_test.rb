# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

module Clusters
  class StrictTipSyncJobTest < ActiveSupport::TestCase
    class AdvisoryLockConnection < ActiveRecord::Base
      self.abstract_class = true
    end

    test "owns the operational lock and invokes the syncer exactly once" do
      job = StrictTipSyncJob.new
      calls = []
      released = 0
      job.stub(:acquire_operational_lock, -> { job.instance_variable_set(:@lock_acquired, true) }) do
        job.stub(:release_operational_lock, -> { released += 1 }) do
          StrictTipSyncer.stub(:call, ->(**arguments) { calls << arguments; { ok: true, status: "synced" } }) do
            StrictTipSyncer.stub(:work_available?, false) do
              result = job.perform(limit: 3, start_height: 100)
              assert_equal "synced", result[:status]
            end
          end
        end
      end

      assert_equal [{ limit: 3, start_height: 100 }], calls
      assert_equal 1, released
    end

    test "a held lock prevents sync and scheduling" do
      job = StrictTipSyncJob.new
      job.stub(:acquire_operational_lock, false) do
        StrictTipSyncer.stub(:call, ->(**) { flunk "must not sync" }) do
          assert_equal "operational_lock_held", job.perform[:reason]
        end
      end
    end

    test "schedules exactly once when the PostgreSQL probe finds remaining work" do
      job = StrictTipSyncJob.new
      scheduled = []
      relation = Object.new
      relation.define_singleton_method(:perform_later) { |**arguments| scheduled << arguments }
      job.stub(:acquire_operational_lock, -> { job.instance_variable_set(:@lock_acquired, true) }) do
        job.stub(:release_operational_lock, true) do
          StrictTipSyncer.stub(:call, { ok: true, status: "synced" }) do
            StrictTipSyncer.stub(:work_available?, true) do
              StrictTipSyncJob.stub(:set, ->(wait:) {
                assert_equal 1.second, wait
                relation
              }) do
                job.perform(limit: 2)
              end
            end
          end
        end
      end

      assert_equal [{ limit: 2, start_height: nil }], scheduled
    end

    test "propagates sync errors and releases the lock without scheduling" do
      job = StrictTipSyncJob.new
      error = RuntimeError.new("sync failed")
      released = 0
      job.stub(:acquire_operational_lock, -> { job.instance_variable_set(:@lock_acquired, true) }) do
        job.stub(:release_operational_lock, -> { released += 1 }) do
          StrictTipSyncer.stub(:call, ->(**) { raise error }) do
            raised = assert_raises(RuntimeError) { job.perform }
            assert_same error, raised
          end
        end
      end
      assert_equal 1, released
    end

    test "uses only the cluster strict queue" do
      assert_equal "cluster_strict", StrictTipSyncJob.new.queue_name
    end

    test "the PostgreSQL operational lock admits only one owner" do
      locked = Queue.new
      release = Queue.new
      holder_class = AdvisoryLockConnection
      holder_class.establish_connection(ActiveRecord::Base.connection_db_config)
      thread = Thread.new do
        holder_class.connection_pool.with_connection do |connection|
          connection.select_value(
            "SELECT pg_advisory_lock(#{StrictTipSyncJob::LOCK_NAMESPACE}, #{StrictTipSyncJob::LOCK_ID})"
          )
          locked << true
          release.pop
          connection.select_value(
            "SELECT pg_advisory_unlock(#{StrictTipSyncJob::LOCK_NAMESPACE}, #{StrictTipSyncJob::LOCK_ID})"
          )
        end
      end
      locked.pop

      contender = StrictTipSyncJob.new
      assert_equal false, contender.send(:acquire_operational_lock)
    ensure
      release << true if release&.empty?
      thread&.join
      holder_class&.connection_pool&.disconnect!
    end
  end
end
