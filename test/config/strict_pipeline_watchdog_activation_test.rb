# frozen_string_literal: true

require "test_helper"
require "shellwords"
require "fugit"
require Rails.root.join("lib/strict_pipeline/watchdog_schedule").to_s

class StrictPipelineWatchdogActivationTest < ActiveSupport::TestCase
  test "uses a bounded thirty second default and a valid configured cadence" do
    assert_equal 30, StrictPipeline::WatchdogSchedule.interval_seconds(env: {})
    assert_equal "*/30 * * * * *", StrictPipeline::WatchdogSchedule.cron(env: {})
    assert Fugit::Cron.parse(StrictPipeline::WatchdogSchedule.cron(env: {}))
    env = { StrictPipeline::WatchdogSchedule::ENV_NAME => "60" }
    assert_equal 60, StrictPipeline::WatchdogSchedule.interval_seconds(env: env)
    assert_equal "* * * * *", StrictPipeline::WatchdogSchedule.cron(env: env)
    assert Fugit::Cron.parse(StrictPipeline::WatchdogSchedule.cron(env: env))
  end

  test "refuses invalid aggressive and irregular cadence values" do
    ["", "zero", "0", "-30", "10", "45", "61"].each do |value|
      env = { StrictPipeline::WatchdogSchedule::ENV_NAME => value }
      assert_raises(StrictPipeline::WatchdogSchedule::ConfigurationError) do
        StrictPipeline::WatchdogSchedule.cron(env: env)
      end
    end
  end

  test "declares one sidekiq-cron trigger without direct business production" do
    source = File.read(Rails.root.join("config/initializers/sidekiq_cron.rb"))
    block = source[/"strict_pipeline_watchdog"\s*=>\s*\{.*?\n\s*\}/m]

    assert_equal 1, source.scan(/"strict_pipeline_watchdog"\s*=>/).size
    assert_includes block, '"cron" => StrictPipeline::WatchdogSchedule.cron'
    assert_includes block, '"class" => "StrictPipeline::SchedulerWatchdogJob"'
    assert_includes block, '"queue" => "scheduler"'
    assert_includes block, '"active_job" => true'
    assert_no_match(/StrictTipSyncJob|StrictWindowRebuilder|ActorProfileHandoffDispatchJob/, block)
  end

  test "declares one isolated scheduler consumer" do
    lines = File.readlines(Rails.root.join("Procfile.dev"), chomp: true)
    declarations = lines.grep(/\Asidekiq_scheduler:/)

    assert_equal 1, declarations.size
    words = Shellwords.split(declarations.sole.split(":", 2).last)
    assert_includes words.each_cons(2).to_a, ["-c", "1"]
    assert_equal ["scheduler"], words.each_cons(2).filter_map { |a, b| b if a == "-q" }
    assert_includes words.each_cons(3).to_a, ["nice", "-n", "19"]
    assert_match(/bundle exec sidekiq/, declarations.sole)
    assert_no_match(/cluster_strict|layer1_strict|actor_profile_strict/, declarations.sole)
  end
end
