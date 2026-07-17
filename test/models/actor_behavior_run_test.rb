# frozen_string_literal: true

require "test_helper"

class ActorBehaviorRunTest < ActiveSupport::TestCase
  test "validates minimal required fields" do
    run =
      ActorBehaviorRun.new

    refute run.valid?
    assert run.errors.added?(:behavior_version, :blank)
    assert run.errors.added?(:mode, :blank)
    assert run.errors.added?(:trigger, :blank)
    assert run.errors.added?(:requested_limit, :blank)
    assert run.errors.added?(:status, :blank)
    assert run.errors.added?(:started_at, :blank)
  end

  test "allows only known statuses" do
    ActorBehaviorRun::STATUSES.each do |status|
      attributes =
        status == "completed_with_errors" ? { failed_count: 1, selected: 1 } : {}

      assert build_run(status: status, **attributes).valid?, status
    end
  end

  test "rejects invalid status" do
    run =
      build_run(status: "critical")

    refute run.valid?
    assert run.errors.added?(:status, :inclusion, value: "critical")
  end

  test "running scope returns running runs" do
    running =
      create_run(status: "running")

    create_run(status: "completed")

    assert_equal [running], ActorBehaviorRun.running.to_a
  end

  test "completed scope returns completed runs" do
    completed =
    create_run(status: "completed")

    create_run(
      status: "completed_with_errors",
      selected: 1,
      failed_count: 1
    )

    assert_equal [completed], ActorBehaviorRun.completed.to_a
  end

  test "successful scope returns completed runs without errors" do
    successful =
      create_run(status: "completed")

    create_run(
      status: "completed_with_errors",
      selected: 1,
      failed_count: 1
    )

    assert_equal [successful], ActorBehaviorRun.successful.to_a
  end

  test "stale_running scope uses explicit threshold" do
    stale =
      create_run(
        status: "running",
        started_at:
          ActorBehaviorRun::STALE_RUNNING_AFTER.ago -
            1.minute
      )

    create_run(
      status: "running",
      started_at:
        ActorBehaviorRun::STALE_RUNNING_AFTER.ago +
          1.minute
    )

    assert_equal [stale], ActorBehaviorRun.stale_running.to_a
  end

  test "stores counters" do
    run =
      create_run(
        selected: 3,
        created_count: 1,
        updated_count: 1,
        unchanged_count: 1
      )

    assert_equal 3, run.selected
    assert_equal 1, run.created_count
    assert_equal 1, run.updated_count
    assert_equal 1, run.unchanged_count
  end

  test "stores reasons" do
    run =
      create_run(
        reasons: {
          "profile_not_certified" => 2
        }
      )

    assert_equal(
      { "profile_not_certified" => 2 },
      run.reasons
    )
  end

  test "does not accept stack traces in error_message" do
    run =
      build_run(
        status: "failed",
        error_message: "RuntimeError: boom\napp/file.rb:1"
      )

    refute run.valid?
    assert run.errors.added?(:error_message, :stack_trace)
  end

  test "validates counter invariant" do
    run =
      build_run(
        selected: 2,
        created_count: 1
      )

    refute run.valid?
    assert run.errors.added?(:selected, :counter_invariant)
  end

  test "running run may have no finished_at" do
    run =
      create_run(status: "running")

    assert_nil run.finished_at
  end

  test "finished run requires finished_at" do
    run =
      build_run(
        status: "completed",
        finished_at: nil
      )

    refute run.valid?
    assert run.errors.added?(:finished_at, :blank)
  end

  test "completed requires no failed profiles" do
    run =
      build_run(
        status: "completed",
        selected: 1,
        failed_count: 1
      )

    refute run.valid?
    assert run.errors.added?(:status, :failed_count_present)
  end

  test "completed_with_errors requires failed profiles" do
    run =
      build_run(status: "completed_with_errors")

    refute run.valid?
    assert run.errors.added?(:status, :failed_count_missing)
  end

  private

  def create_run(**attributes)
    build_run(**attributes).tap(&:save!)
  end

  def build_run(**attributes)
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
        status == "running" ? nil : 5,
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

    ActorBehaviorRun.new(
      defaults.merge(attributes)
    )
  end
end
