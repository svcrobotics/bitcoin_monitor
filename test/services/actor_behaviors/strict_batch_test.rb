# frozen_string_literal: true

require "test_helper"
require_relative "../../support/actor_behavior_test_helper"

module ActorBehaviors
  class StrictBatchTest < ActiveSupport::TestCase
    include ActorBehaviorTestHelper

    test "creates several snapshots" do
      2.times do
        create_certified_actor_profile
      end

      assert_difference -> { ActorBehaviorRun.count }, 1 do
        result =
          ActorBehaviors::StrictBatch.call(limit: 10)

        assert_equal "completed", result[:status]
        assert_equal 2, result[:created]
        assert_equal 2, ActorBehaviorSnapshot.count
      end
    end

    test "creates exactly one run per call" do
      create_certified_actor_profile

      assert_difference -> { ActorBehaviorRun.count }, 1 do
        ActorBehaviors::StrictBatch.call(limit: 10)
      end

      run =
        ActorBehaviorRun.last

      assert_equal "completed", run.status
      assert_equal 1, run.selected
      assert_equal 1, run.created_count
    end

    test "run starts as running before profiles are processed" do
      selection = {
        profiles: [],
        missing_selected: 0,
        stale_selected: 0
      }

      implementation =
        lambda do |limit:|
          run =
            ActorBehaviorRun.last

          assert_equal 10, limit
          assert_equal "running", run.status
          assert_nil run.finished_at

          selection
        end

      with_stubbed(ActorBehaviors::StrictBatchBuilder, :call, implementation) do
        result =
          ActorBehaviors::StrictBatch.call(limit: 10)

        assert_equal "completed", result[:run_status]
      end
    end

    test "run terminates completed on success" do
      create_certified_actor_profile

      result =
        ActorBehaviors::StrictBatch.call(limit: 10)

      assert_equal "completed", result[:status]
      assert_equal result[:run_id], ActorBehaviorRun.last.id
      assert_equal "completed", result[:run_status]
      assert_equal "completed", ActorBehaviorRun.last.status
      assert ActorBehaviorRun.last.finished_at.present?
    end

    test "updates stale snapshots" do
      profile =
        create_certified_actor_profile

      create_current_behavior_snapshot(profile).update!(
        status: "failed"
      )

      result =
        ActorBehaviors::StrictBatch.call(limit: 10)

      assert_equal 1, result[:updated]
      assert_equal "certified", ActorBehaviorSnapshot.first.status
    end

    test "counts created updated and unchanged" do
      missing =
        create_certified_actor_profile

      stale =
        create_certified_actor_profile

      unchanged =
        create_certified_actor_profile

      create_current_behavior_snapshot(stale).update!(
        behavior_version: "strict_v0"
      )

      create_current_behavior_snapshot(unchanged)

      selection = {
        profiles: [missing, stale, unchanged],
        missing_selected: 1,
        stale_selected: 2
      }

      with_stubbed(ActorBehaviors::StrictBatchBuilder, :call, selection) do
        result =
          ActorBehaviors::StrictBatch.call(limit: 10)

        assert_equal 1, result[:created]
        assert_equal 1, result[:updated]
        assert_equal 1, result[:unchanged]
      end
    end

    test "counts deferred results" do
      profile =
        create_certified_actor_profile

      selection = {
        profiles: [profile],
        missing_selected: 1,
        stale_selected: 0
      }

      build_result = {
        status: "deferred",
        reason: :profile_not_certified
      }

      with_stubbed(ActorBehaviors::StrictBatchBuilder, :call, selection) do
        with_stubbed(
          ActorBehaviors::StrictBuildFromProfile,
          :call,
          build_result
        ) do
          result =
            ActorBehaviors::StrictBatch.call(limit: 10)

          assert_equal 1, result[:deferred]
          assert_equal 1, result[:reasons][:profile_not_certified]
        end
      end
    end

    test "exception on one profile does not stop next profiles" do
      first =
        create_certified_actor_profile

      second =
        create_certified_actor_profile

      selection = {
        profiles: [first, second],
        missing_selected: 2,
        stale_selected: 0
      }

      calls = 0

      implementation =
        lambda do |actor_profile:|
          calls += 1
          raise "boom" if actor_profile == first

          {
            status: "certified",
            created: true,
            updated: false,
            unchanged: false
          }
        end

      with_stubbed(ActorBehaviors::StrictBatchBuilder, :call, selection) do
        with_stubbed(
          ActorBehaviors::StrictBuildFromProfile,
          :call,
          implementation
        ) do
          result =
            ActorBehaviors::StrictBatch.call(limit: 10)

          assert_equal 2, calls
          assert_equal 1, result[:failed]
          assert_equal 1, result[:created]
          assert_equal 1, result[:reasons][:unexpected_error]
          assert_equal "completed_with_errors", result[:status]

          run =
            ActorBehaviorRun.find(result.fetch(:run_id))

          assert_equal "completed_with_errors", run.status
          assert_equal 1, run.failed_count
          assert_equal(
            { "unexpected_error" => 1 },
            run.reasons
          )
        end
      end
    end

    test "global error marks run failed and re-raises" do
      profile =
        create_certified_actor_profile

      selection = {
        profiles:
          raising_after_first_profile(
            profile,
            RuntimeError.new("global boom\napp/file.rb:1")
          ),
        missing_selected: 1,
        stale_selected: 0
      }

      with_stubbed(ActorBehaviors::StrictBatchBuilder, :call, selection) do
        assert_raises RuntimeError do
          ActorBehaviors::StrictBatch.call(
            limit: 10,
            trigger: "test"
          )
        end
      end

      run =
        ActorBehaviorRun.last

      assert_equal "failed", run.status
      assert_equal "RuntimeError", run.error_code
      assert_equal "RuntimeError: global boom app/file.rb:1", run.error_message
      assert_equal 1, run.selected
      assert_equal 1, ActorBehaviorSnapshot.count
    end

    test "does not count the full certified scope on batch startup" do
      create_certified_actor_profile

      count_queries = []

      callback =
        lambda do |_name, _started, _finished, _id, payload|
          sql = payload[:sql].to_s.downcase

          if sql.include?("count(*)") &&
             sql.include?('from "actor_profiles"')
            count_queries << sql
          end
        end

      ActiveSupport::Notifications.subscribed(
        callback,
        "sql.active_record"
      ) do
        ActorBehaviors::StrictBatch.call(limit: 1)
      end

      assert_empty count_queries
      assert_nil(
        ActorBehaviorRun.last.actor_profiles_certified_at_start
      )
    end

    test "does not open a global transaction" do
      source =
        Rails.root.join(
          "app/services/actor_behaviors/strict_batch.rb"
        ).read

      refute_match(/\.transaction\b/, source)
    end

    test "does not modify actor profiles or actor labels" do
      profile =
        create_certified_actor_profile

      before_attributes =
        profile.reload.attributes

      assert_no_difference -> { ActorLabel.count } do
        ActorBehaviors::StrictBatch.call(limit: 10)
      end

      assert_equal before_attributes, profile.reload.attributes
    end

    test "does not query tx_outputs" do
      create_certified_actor_profile
      queries = []

      callback =
        lambda do |_name, _started, _finished, _id, payload|
          sql = payload[:sql].to_s.downcase
          queries << sql if sql.include?("tx_outputs")
        end

      ActiveSupport::Notifications.subscribed(
        callback,
        "sql.active_record"
      ) do
        ActorBehaviors::StrictBatch.call(limit: 10)
      end

      assert_empty queries
    end

    test "uses conservative default limit and caps maximum" do
      assert_equal 25, ActorBehaviors::StrictBatch::DEFAULT_LIMIT
      assert_equal 500, ActorBehaviors::StrictBatch.normalize_limit(5_000)
      assert_equal 25, ActorBehaviors::StrictBatch.normalize_limit("bad")
      assert_equal 1, ActorBehaviors::StrictBatch.normalize_limit(0)
    end

    test "two identical executions become idempotent" do
      create_certified_actor_profile

      first =
        ActorBehaviors::StrictBatch.call(limit: 10)

      second =
        ActorBehaviors::StrictBatch.call(limit: 10)

      assert_equal 1, first[:created]
      assert_equal 0, second[:created]
      assert_equal 0, second[:updated]
      assert_equal 0, second[:selected]
      assert_equal 1, ActorBehaviorSnapshot.count
    end

    test "cooperative guard defers remaining profiles without processing them" do
      first =
        create_certified_actor_profile

      second =
        create_certified_actor_profile

      selection = {
        profiles: [first, second],
        missing_selected: 2,
        stale_selected: 0
      }

      calls = 0

      guard =
        lambda do
          calls += 1
          calls > 1 ? :layer1_realtime_priority : nil
        end

      with_stubbed(ActorBehaviors::StrictBatchBuilder, :call, selection) do
        result =
          ActorBehaviors::StrictBatch.call(
            limit: 10,
            trigger: "test",
            cooperative_guard: guard
          )

        assert_equal "completed", result[:status]
        assert_equal 2, result[:selected]
        assert_equal 1, result[:created]
        assert_equal 1, result[:deferred]
        assert_equal 1, result[:reasons][:layer1_realtime_priority]
        assert_equal 1, ActorBehaviorSnapshot.count
        assert_equal first.cluster_id, ActorBehaviorSnapshot.first.cluster_id
      end
    end

    test "result contains duration and reasons" do
      create_certified_actor_profile(dirty: true)

      selection = {
        profiles: [ActorProfile.last],
        missing_selected: 1,
        stale_selected: 0
      }

      with_stubbed(ActorBehaviors::StrictBatchBuilder, :call, selection) do
        result =
          ActorBehaviors::StrictBatch.call(limit: 10)

        assert_kind_of Integer, result[:duration_ms]
        assert result.key?(:reasons)
        assert_kind_of Integer, result[:run_id]
        assert_equal "completed", result[:run_status]
      end
    end

    test "run counters and reasons match returned result" do
      profile =
        create_certified_actor_profile

      selection = {
        profiles: [profile],
        missing_selected: 1,
        stale_selected: 0
      }

      build_result = {
        status: "deferred",
        reason: :profile_not_certified
      }

      with_stubbed(ActorBehaviors::StrictBatchBuilder, :call, selection) do
        with_stubbed(
          ActorBehaviors::StrictBuildFromProfile,
          :call,
          build_result
        ) do
          result =
            ActorBehaviors::StrictBatch.call(
              limit: 10,
              trigger: "test"
            )

          run =
            ActorBehaviorRun.find(result.fetch(:run_id))

          assert_equal result[:selected], run.selected
          assert_equal result[:missing_selected], run.missing_selected
          assert_equal result[:stale_selected], run.stale_selected
          assert_equal result[:created], run.created_count
          assert_equal result[:updated], run.updated_count
          assert_equal result[:unchanged], run.unchanged_count
          assert_equal result[:deferred], run.deferred_count
          assert_equal result[:failed], run.failed_count
          assert_equal(
            result[:reasons].transform_keys(&:to_s),
            run.reasons
          )
          assert run.duration_ms >= 0
          assert run.finished_at >= run.started_at
        end
      end
    end

    test "uses manual trigger by default" do
      ActorBehaviors::StrictBatch.call(limit: 10)

      assert_equal "manual", ActorBehaviorRun.last.trigger
    end

    test "accepts test trigger" do
      ActorBehaviors::StrictBatch.call(
        limit: 10,
        trigger: "test"
      )

      assert_equal "test", ActorBehaviorRun.last.trigger
    end

    test "keeps legacy result keys" do
      result =
        ActorBehaviors::StrictBatch.call(limit: 10)

      %i[
        ok
        status
        requested_limit
        selected
        missing_selected
        stale_selected
        created
        updated
        unchanged
        deferred
        failed
        duration_ms
        reasons
      ].each do |key|
        assert result.key?(key), key
      end
    end

    test "modified profile behind old id is selected in next batch" do
      old_profile =
        create_certified_actor_profile

      newer_profile =
        create_certified_actor_profile

      create_current_behavior_snapshot(old_profile)
      snapshot =
        create_current_behavior_snapshot(newer_profile)

      old_profile.update!(
        balance_btc: "12000.0"
      )

      snapshot.update!(
        status: "failed"
      )

      result =
        ActorBehaviors::StrictBatch.call(limit: 1)

      assert_equal 1, result[:updated]
      assert_equal(
        100,
        ActorBehaviorSnapshot
          .find_by(cluster_id: old_profile.cluster_id)
          .scores["whale_score"]
      )
      assert_equal "failed", snapshot.reload.status
    end

    private

    def with_stubbed(object, method_name, replacement)
      singleton =
        class << object
          self
        end

      original =
        :"#{method_name}_without_actor_behavior_test"

      singleton.alias_method original, method_name

      singleton.define_method(method_name) do |*args, **kwargs, &block|
        if replacement.respond_to?(:call)
          replacement.call(*args, **kwargs, &block)
        else
          replacement
        end
      end

      yield
    ensure
      singleton.alias_method method_name, original
      singleton.remove_method original
    end

    def raising_after_first_profile(profile, error)
      Class.new do
        define_method(:initialize) do |profile_arg, error_arg|
          @profile =
            profile_arg

          @error =
            error_arg
        end

        define_method(:each) do |&block|
          block.call(@profile)
          raise @error
        end
      end.new(profile, error)
    end
  end
end
