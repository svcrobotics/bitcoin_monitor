# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

module StrictPipeline
  class SchedulerWatchdogJobTest < ActiveSupport::TestCase
    test "uses the dedicated scheduler queue and calls the watchdog exactly once" do
      calls = 0
      releases = 0
      expected = { ok: true, jobs: [] }
      job = SchedulerWatchdogJob.new

      job.stub(:acquire_scheduler_lock, -> {
        job.instance_variable_set(:@scheduler_lock_acquired, true)
      }) do
        job.stub(:release_scheduler_lock_without_masking, -> { releases += 1 }) do
          SchedulerWatchdog.stub(:call, -> { calls += 1; expected }) do
            assert_same expected, job.perform
          end
        end
      end

      assert_equal 1, calls
      assert_equal 1, releases
      assert_equal "scheduler", SchedulerWatchdogJob.new.queue_name
    end

    test "propagates the original watchdog error" do
      error = RuntimeError.new("watchdog failed")
      releases = 0
      job = SchedulerWatchdogJob.new

      job.stub(:acquire_scheduler_lock, -> {
        job.instance_variable_set(:@scheduler_lock_acquired, true)
      }) do
        job.stub(:release_scheduler_lock_without_masking, -> { releases += 1 }) do
          SchedulerWatchdog.stub(:call, -> { raise error }) do
            raised = assert_raises(RuntimeError) { job.perform }
            assert_same error, raised
          end
        end
      end
      assert_equal 1, releases
    end

    test "two concurrent triggers execute only one watchdog cycle" do
      mutex = Mutex.new
      held = false
      entered = Queue.new
      release = Queue.new
      results = Queue.new
      calls = 0
      acquire = lambda do |job|
        mutex.synchronize do
          next false if held

          held = true
          job.instance_variable_set(:@scheduler_lock_acquired, true)
          true
        end
      end
      release_lock = -> { mutex.synchronize { held = false } }
      first_job = SchedulerWatchdogJob.new
      second_job = SchedulerWatchdogJob.new

      SchedulerWatchdog.stub(:call, -> { calls += 1; entered << true; release.pop; { ok: true } }) do
        first = Thread.new do
          first_job.stub(:acquire_scheduler_lock, -> { acquire.call(first_job) }) do
            first_job.stub(:release_scheduler_lock_without_masking, release_lock) do
              results << first_job.perform
            end
          end
        end
        entered.pop
        second = Thread.new do
          second_job.stub(:acquire_scheduler_lock, -> { acquire.call(second_job) }) do
            second_job.stub(:release_scheduler_lock_without_masking, release_lock) do
              results << second_job.perform
            end
          end
        end
        second.join
        release << true
        first.join
      end

      values = 2.times.map { results.pop }
      assert_equal 1, values.count { |value| value[:skipped] == true }
      assert_equal 1, values.count { |value| value[:ok] == true && !value[:skipped] }
      assert_equal 1, calls
    end

    test "an unlock failure does not mask the watchdog error" do
      watchdog_error = RuntimeError.new("watchdog failed")
      unlock_error = RuntimeError.new("unlock failed")
      job = SchedulerWatchdogJob.new
      logger = Minitest::Mock.new
      logger.expect(:error, nil, [String])

      job.stub(:acquire_scheduler_lock, -> {
        job.instance_variable_set(:@scheduler_lock_acquired, true)
      }) do
        job.stub(:release_scheduler_lock, -> { raise unlock_error }) do
          Rails.stub(:logger, logger) do
            SchedulerWatchdog.stub(:call, -> { raise watchdog_error }) do
              raised = assert_raises(RuntimeError) { job.perform }
              assert_same watchdog_error, raised
            end
          end
        end
      end
      logger.verify
    end

    test "uses only PostgreSQL advisory SQL and produces no business jobs itself" do
      queries = []
      connection = Object.new
      connection.define_singleton_method(:select_value) do |sql|
        queries << sql
        sql.include?("pg_try_advisory_lock") ? true : true
      end

      ApplicationRecord.stub(:connection, connection) do
        SchedulerWatchdog.stub(:call, { ok: true, jobs: [] }) do
          SchedulerWatchdogJob.new.perform
        end
      end
      source = File.read(Rails.root.join("app/jobs/strict_pipeline/scheduler_watchdog_job.rb"))

      assert_equal 2, queries.size
      assert_match(/pg_try_advisory_lock\(41023, 1\)/, queries.first)
      assert_match(/pg_advisory_unlock\(41023, 1\)/, queries.last)
      assert queries.none? { |sql| sql.match?(/\b(?:FROM|INSERT|UPDATE|DELETE)\b/i) }
      assert_no_match(/StrictTipSyncJob|StrictWindowRebuilder|ActorProfileHandoffDispatchJob/, source)
      assert_no_match(/perform_(?:later|async|in)/, source)
    end
  end
end
