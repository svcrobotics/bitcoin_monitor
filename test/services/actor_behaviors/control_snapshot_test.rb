# frozen_string_literal: true

require "test_helper"
require_relative "../../support/actor_behavior_test_helper"

module ActorBehaviors
  class ControlSnapshotTest < ActiveSupport::TestCase
    include ActorBehaviorTestHelper

    setup do
      Sidekiq.redis do |redis|
        redis.del(StrictPipeline::Scheduler::RUNTIME_STATUS_KEY)
      end
    end

    test "flag absent disables automation" do
      with_env("ACTOR_BEHAVIOR_AUTO_ENABLED" => nil) do
        refute ActorBehaviors::ControlSnapshot.call[:auto_enabled]
      end
    end

    test "flag explicitly false disables automation" do
      with_env("ACTOR_BEHAVIOR_AUTO_ENABLED" => "false") do
        refute ActorBehaviors::ControlSnapshot.call[:auto_enabled]
      end
    end

    test "flag explicitly true enables automation" do
      with_env("ACTOR_BEHAVIOR_AUTO_ENABLED" => "true") do
        assert ActorBehaviors::ControlSnapshot.call[:auto_enabled]
      end
    end

    test "fresh scheduler heartbeat enables automation even when local web flag is false" do
      payload = {
        observed_at: Time.current.iso8601(6),
        pid: 12_345,
        queue: "scheduler",
        scheduler_enabled: true,
        actor_behavior_auto_enabled: true
      }

      Sidekiq.redis do |redis|
        redis.set(
          StrictPipeline::Scheduler::RUNTIME_STATUS_KEY,
          JSON.generate(payload),
          ex: StrictPipeline::Scheduler::RUNTIME_STATUS_TTL_SECONDS
        )
      end

      with_env("ACTOR_BEHAVIOR_AUTO_ENABLED" => "false") do
        snapshot = ActorBehaviors::ControlSnapshot.call

        assert snapshot[:scheduler_runtime_fresh]
        assert snapshot[:scheduler_actor_behavior_auto_enabled]
        assert snapshot[:auto_enabled]
        refute snapshot[:local_auto_enabled]
      end
    ensure
      Sidekiq.redis do |redis|
        redis.del(StrictPipeline::Scheduler::RUNTIME_STATUS_KEY)
      end
    end

    test "expired scheduler heartbeat does not enable automation" do
      payload = {
        observed_at: 10.minutes.ago.iso8601(6),
        pid: 12_345,
        queue: "scheduler",
        scheduler_enabled: true,
        actor_behavior_auto_enabled: true
      }

      Sidekiq.redis do |redis|
        redis.set(
          StrictPipeline::Scheduler::RUNTIME_STATUS_KEY,
          JSON.generate(payload)
        )
      end

      with_env("ACTOR_BEHAVIOR_AUTO_ENABLED" => "false") do
        snapshot = ActorBehaviors::ControlSnapshot.call

        refute snapshot[:scheduler_runtime_fresh]
        refute snapshot[:auto_enabled]
      end
    ensure
      Sidekiq.redis do |redis|
        redis.del(StrictPipeline::Scheduler::RUNTIME_STATUS_KEY)
      end
    end

    test "reports no certified profiles" do
      snapshot =
        ActorBehaviors::ControlSnapshot.call

      refute snapshot[:certified_profiles_available]
    end

    test "reports certified profiles available" do
      create_certified_actor_profile

      assert ActorBehaviors::ControlSnapshot.call[:certified_profiles_available]
    end

    test "reports missing work available" do
      create_certified_actor_profile

      snapshot =
        ActorBehaviors::ControlSnapshot.call

      assert snapshot[:missing_work_available]
      assert snapshot[:work_available]
    end

    test "reports stale work available" do
      profile =
        create_certified_actor_profile

      create_current_behavior_snapshot(profile).update!(
        behavior_version: "strict_v0"
      )

      snapshot =
        ActorBehaviors::ControlSnapshot.call

      refute snapshot[:missing_work_available]
      assert snapshot[:stale_work_available]
      assert snapshot[:work_available]
    end

    test "reports no work available" do
      profile =
        create_certified_actor_profile

      create_current_behavior_snapshot(profile)

      snapshot =
        ActorBehaviors::ControlSnapshot.call

      refute snapshot[:missing_work_available]
      refute snapshot[:stale_work_available]
      refute snapshot[:work_available]
    end

    test "reports active run" do
      create_behavior_run(status: "running")

      snapshot =
        ActorBehaviors::ControlSnapshot.call

      assert snapshot[:batch_running]
      refute snapshot[:stale_running_run]
    end

    test "reports stale run" do
      create_behavior_run(
        status: "running",
        started_at:
          ActorBehaviorRun::STALE_RUNNING_AFTER.ago -
            1.minute
      )

      snapshot =
        ActorBehaviors::ControlSnapshot.call

      refute snapshot[:batch_running]
      assert snapshot[:stale_running_run]
    end

    test "reports last completed run" do
      run =
        create_behavior_run(status: "completed")

      snapshot =
        ActorBehaviors::ControlSnapshot.call

      assert_equal "completed", snapshot[:last_run_status]
      assert_equal run.finished_at, snapshot[:last_run_finished_at]
    end

    test "reports last failed run" do
      create_behavior_run(
        status: "failed",
        error_code: "RuntimeError",
        error_message: "RuntimeError: boom"
      )

      assert_equal(
        "failed",
        ActorBehaviors::ControlSnapshot.call[:last_run_status]
      )
    end

    test "reports no historical run" do
      snapshot =
        ActorBehaviors::ControlSnapshot.call

      assert_nil snapshot[:last_run_status]
      assert_nil snapshot[:last_run_finished_at]
    end

    test "does not call operational snapshot" do
      with_stubbed(
        ActorBehaviors::OperationalSnapshot,
        :call,
        -> { raise "operational snapshot must not be called" }
      ) do
        assert_nothing_raised do
          ActorBehaviors::ControlSnapshot.call
        end
      end
    end

    test "does not call strict health snapshot" do
      with_stubbed(
        ActorBehaviors::StrictHealthSnapshot,
        :call,
        -> { raise "strict health snapshot must not be called" }
      ) do
        assert_nothing_raised do
          ActorBehaviors::ControlSnapshot.call
        end
      end
    end

    test "does not load all profiles" do
      3.times do
        create_certified_actor_profile
      end

      actor_profile_loads = []

      callback =
        lambda do |_name, _started, _finished, _id, payload|
          sql =
            payload[:sql].to_s

          actor_profile_loads << sql if sql.match?(/SELECT\s+"actor_profiles"\.\*/i)
        end

      ActiveSupport::Notifications.subscribed(
        callback,
        "sql.active_record"
      ) do
        ActorBehaviors::ControlSnapshot.call
      end

      assert_empty actor_profile_loads
    end

    test "does not write data" do
      profile =
        create_certified_actor_profile

      create_current_behavior_snapshot(profile)

      assert_no_difference -> { ActorBehaviorSnapshot.count } do
        assert_no_difference -> { ActorBehaviorRun.count } do
          assert_no_difference -> { ActorProfile.count } do
            assert_no_difference -> { ActorLabel.count } do
              ActorBehaviors::ControlSnapshot.call
            end
          end
        end
      end
    end

    test "uses a bounded query budget" do
      create_certified_actor_profile
      queries = []

      callback =
        lambda do |_name, _started, _finished, _id, payload|
          next if payload[:name].to_s == "SCHEMA"

          sql =
            payload[:sql].to_s

          next if sql.match?(/\A(?:BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i)

          queries << sql
        end

      ActiveSupport::Notifications.subscribed(
        callback,
        "sql.active_record"
      ) do
        ActorBehaviors::ControlSnapshot.call
      end

      assert_operator queries.size, :<=, 8
    end

    private

    def create_behavior_run(**attributes)
      status =
        attributes.fetch(:status, "completed")

      defaults = {
        behavior_version:
          ActorBehaviors::StrictBuildFromProfile::BEHAVIOR_VERSION,
        mode: "shadow",
        trigger: "test",
        requested_limit: 25,
        status: status,
        started_at: Time.current,
        finished_at:
          status == "running" ? nil : Time.current,
        duration_ms:
          status == "running" ? nil : 10,
        selected: 0,
        missing_selected: 0,
        stale_selected: 0,
        created_count: 0,
        updated_count: 0,
        unchanged_count: 0,
        deferred_count: 0,
        failed_count: 0,
        reasons: {}
      }

      ActorBehaviorRun.create!(
        defaults.merge(attributes)
      )
    end

    def with_env(values)
      old_values = {}

      values.each_key do |key|
        old_values[key] =
          ENV[key]
      end

      values.each do |key, value|
        if value.nil?
          ENV.delete(key)
        else
          ENV[key] = value
        end
      end

      yield
    ensure
      old_values.each do |key, value|
        if value.nil?
          ENV.delete(key)
        else
          ENV[key] = value
        end
      end
    end

    def with_stubbed(object, method_name, value = nil)
      original =
        object.method(method_name)

      replacement =
        if value.respond_to?(:call)
          value
        else
          ->(*_args, **_kwargs) { value }
        end

      object.define_singleton_method(method_name, &replacement)

      yield
    ensure
      object.define_singleton_method(method_name) do |*args, **kwargs, &block|
        original.call(*args, **kwargs, &block)
      end
    end
  end
end
