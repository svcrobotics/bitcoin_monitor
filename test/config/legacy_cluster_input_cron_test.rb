# frozen_string_literal: true

require "test_helper"

class LegacyClusterInputCronTest < ActiveSupport::TestCase
  INITIALIZER = Rails.root.join("config/initializers/sidekiq_cron.rb")
  PROCFILE = Rails.root.join("Procfile.dev")
  FLAG = "TANSA_LEGACY_CLUSTER_INPUT_ORCHESTRATOR_ENABLED"

  test "cluster input orchestrator is absent by default and for every non-true value" do
    [nil, "", " ", "0", "false", "off", "no", "invalid", "TRUE", " true "].each do |value|
      schedule = load_schedule(value)

      refute schedule.key?("cluster_input_orchestrator"), value.inspect
    end
  end

  test "only explicit true values include the legacy cluster input orchestrator" do
    %w[1 true yes on].each do |value|
      schedule = load_schedule(value)

      assert_equal(
        {
          "class" => "Clusters::ClusterInputOrchestratorJob",
          "cron" => "*/1 * * * *",
          "queue" => "p3_clusters_scan"
        },
        schedule.fetch("cluster_input_orchestrator"),
        value
      )
    end
  end

  test "the flag changes no other cron schedule" do
    disabled = load_schedule(nil)
    enabled = load_schedule("1")

    assert_equal ["cluster_input_orchestrator"], enabled.keys - disabled.keys
    assert_equal disabled, enabled.except("cluster_input_orchestrator")
  end

  test "loading the initializer uses only the schedule loader double" do
    redis_calls = 0
    enqueue_calls = 0

    with_singleton_method(Sidekiq, :redis, ->(*) { redis_calls += 1 }) do
      with_singleton_method(Clusters::ClusterInputOrchestratorJob, :perform_async, ->(*) { enqueue_calls += 1 }) do
        load_schedule("1")
      end
    end

    assert_equal 0, redis_calls
    assert_equal 0, enqueue_calls
  end

  test "the legacy p3 cluster consumer remains commented in Procfile" do
    lines = PROCFILE.readlines(chomp: true)
    active_lines = lines.reject { |line| line.lstrip.start_with?("#") }

    assert lines.any? { |line| line.start_with?("#sidekiq_clusters:") }
    refute active_lines.any? { |line| line.include?("p3_clusters_scan") }
  end

  private

  def load_schedule(value)
    previous_flag = ENV[FLAG]
    previous_legacy_cron = ENV["SIDEKIQ_LEGACY_CRON"]
    captured = nil

    value.nil? ? ENV.delete(FLAG) : ENV[FLAG] = value
    ENV["SIDEKIQ_LEGACY_CRON"] = "1"

    with_singleton_method(Sidekiq, :server?, -> { true }) do
      with_singleton_method(Sidekiq::Cron::Job, :load_from_hash!, ->(schedule) { captured = Marshal.load(Marshal.dump(schedule)) }) do
        load INITIALIZER
      end
    end

    captured
  ensure
    previous_flag.nil? ? ENV.delete(FLAG) : ENV[FLAG] = previous_flag
    if previous_legacy_cron.nil?
      ENV.delete("SIDEKIQ_LEGACY_CRON")
    else
      ENV["SIDEKIQ_LEGACY_CRON"] = previous_legacy_cron
    end
  end

  def with_singleton_method(target, name, replacement)
    original = target.method(name)
    target.define_singleton_method(name, replacement)
    yield
  ensure
    target.define_singleton_method(name, original)
  end
end
