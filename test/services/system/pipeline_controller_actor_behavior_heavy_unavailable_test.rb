# frozen_string_literal: true

require "test_helper"

module System
  class PipelineControllerActorBehaviorHeavyUnavailableTest < ActiveSupport::TestCase
    test "direct Heavy decision is explicit fail-closed and serializable" do
      input = canonical_snapshot

      result = PipelineController.actor_behavior_heavy_decision(
        current_snapshot: input
      )

      assert_equal :actor_behavior_heavy, result[:module]
      assert_equal false, result[:allowed]
      assert_equal :unavailable, result[:state]
      assert_equal :actor_behavior_heavy_unavailable, result[:reason]
      assert_nil result[:retry_in]
      assert_equal [:actor_behavior_heavy_unavailable], result[:failed_constraints]
      assert_equal false, result.dig(:actor_behavior_heavy, :available)
      assert_equal false, result.dig(:actor_behavior_heavy, :work_available)
      assert_equal :actor_behavior_heavy_unavailable,
        result.dig(:snapshot, :actor_behavior_heavy, :reason)
      assert_equal input[:actor_behavior], result.dig(:snapshot, :actor_behavior)
      assert JSON.generate(result)
    end

    test "global decision path refuses Heavy without consulting missing runtime or Redis" do
      redis_new = Redis.method(:new)
      Redis.define_singleton_method(:new) do |*|
        flunk "Heavy refusal must not instantiate Redis"
      end

      result = PipelineController.decision(
        :actor_behavior_heavy,
        current_snapshot: canonical_snapshot
      )

      assert_equal false, result[:allowed]
      assert_equal :unavailable, result[:state]
      assert_equal :actor_behavior_heavy_unavailable, result[:reason]
      assert_equal false, PipelineController.work_available?(result)
    ensure
      Redis.define_singleton_method(:new, redis_new)
    end

    test "Heavy path has no scheduler or enqueue and clean runtime declares no Heavy consumer" do
      source = File.read(Rails.root.join("app/services/system/pipeline_controller.rb"))
      method_source = source[/def self\.actor_behavior_heavy_decision\(.+?^    end\n/m]
      procfile = File.read(Rails.root.join("Procfile.dev"))
      cron = File.read(Rails.root.join("config/initializers/sidekiq_cron.rb"))

      assert method_source
      refute_match(/ActorBehaviors::Heavy|ControlSnapshot|Redis|Sidekiq|perform_async/, method_source)
      refute_match(/^sidekiq_actor_behavior_heavy:/, procfile)
      refute_match(/actor_behavior_heavy/i, cron)
    end

    private

    def canonical_snapshot
      {
        development_backfill: { enabled: false },
        bitcoin_core: { available: true },
        layer1: { checkpoint_available: true, idle: true, catching_up: false },
        cluster: { checkpoint_available: true, idle: true, caught_up_to_layer1: true },
        actor_profile: { checkpoint_available: true },
        actor_behavior: { work_available: false },
        actor_labels: {},
        strict_io: { owner: nil }
      }
    end
  end
end
