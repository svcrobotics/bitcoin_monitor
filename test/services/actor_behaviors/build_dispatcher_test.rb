# frozen_string_literal: true

require "test_helper"

module ActorBehaviors
  class BuildDispatcherTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    def setup
      cleanup
      @cluster = Cluster.create!(composition_version: 1)
      @profile = ActorProfile.create!(cluster: @cluster)
    end

    def teardown
      cleanup
    end

    test "claims in deterministic order and completes terminal results" do
      second = create_handoff(height: 2)
      first = create_handoff(height: 1)
      seen = []
      implementation = lambda do |**arguments|
        seen << arguments
        { status: "built" }
      end

      with_singleton_method(StrictBuildFromProfile, :call, implementation) do
        result = BuildDispatcher.call(limit: 2)
        assert_equal 2, result[:claimed]
        assert_equal 2, result[:completed]
      end

      seen_ids = seen.map do |arguments|
        ActorBehaviorBuildHandoff.find_by!(
          cluster_id: arguments.fetch(:cluster_id),
          source_height: arguments.fetch(:source_height)
        ).id
      end
      assert_equal [first.id, second.id], seen_ids
      assert_equal [1, 1], [first.reload.attempts, second.reload.attempts]
      assert_equal %w[completed completed], [first.status, second.status]
    end

    test "recovers stale claims and never claims completed rows" do
      stale = create_handoff(height: 3)
      stale.update!(status: "processing", attempts: 1,
        claimed_at: 30.minutes.ago)
      completed = create_handoff(height: 4)
      completed.update!(status: "processing", attempts: 1,
        claimed_at: Time.current)
      completed.complete!

      with_singleton_method(StrictBuildFromProfile, :call, ->(**) { { status: "already_current" } }) do
        result = BuildDispatcher.call(limit: 10)
        assert_equal 1, result[:claimed]
      end

      assert_equal 2, stale.reload.attempts
      assert_equal "completed", stale.status
      assert_equal 1, completed.reload.attempts
    end

    test "refused and exceptional builds remain recoverable" do
      refused = create_handoff(height: 5)
      with_singleton_method(StrictBuildFromProfile, :call,
        ->(**) { { status: "refused", reason: "source_divergent" } }) do
        result = BuildDispatcher.call(limit: 1)
        assert_equal 1, result[:failed]
      end
      assert_equal "failed", refused.reload.status
      assert_equal "ActorBehaviorSourceRefused", refused.last_error_class

      failure = RuntimeError.new("builder failed")
      assert_raises(RuntimeError) do
        with_singleton_method(StrictBuildFromProfile, :call, ->(**) { raise failure }) do
          BuildDispatcher.call(limit: 1)
        end
      end
      assert_equal "failed", refused.reload.status
      assert_equal "RuntimeError", refused.last_error_class
      assert_equal 2, refused.attempts
    end

    test "empty backlog is a JSON serializable no-op" do
      result = BuildDispatcher.call(limit: 10)
      assert_equal 0, result[:claimed]
      assert JSON.generate(result)
      refute BuildDispatcher.work_available?
    end

    test "a locked first row is skipped and remains recoverable" do
      first = create_handoff(height: 1)
      second = create_handoff(height: 2)
      locked = Queue.new
      release = Queue.new
      locker = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ActorBehaviorBuildHandoff.transaction do
            ActorBehaviorBuildHandoff.lock.find(first.id)
            locked << true
            release.pop
          end
        end
      end
      locked.pop

      with_singleton_method(StrictBuildFromProfile, :call, ->(**) { { status: "built" } }) do
        result = BuildDispatcher.call(limit: 1)
        assert_equal second.id, result.dig(:results, 0, :handoff_id)
      end
      assert_equal "pending", first.reload.status
      assert BuildDispatcher.work_available?
    ensure
      release << true if defined?(release)
      locker&.join
    end

    private

    def create_handoff(height:)
      ActorBehaviorBuildHandoff.create!(
        cluster: @cluster,
        actor_profile: @profile,
        cluster_composition_version: 1,
        profile_version: "strict_v3_core",
        source_height: height,
        source_hash: "hash-#{height}"
      )
    end

    def with_singleton_method(target, method_name, replacement)
      singleton = target.singleton_class
      original = :"#{method_name}_without_dispatcher_test"
      singleton.alias_method(original, method_name)
      singleton.define_method(method_name, &replacement)
      yield
    ensure
      singleton.alias_method(method_name, original)
      singleton.remove_method(original)
    end

    def cleanup
      ActorBehaviorSnapshot.delete_all
      ActorBehaviorBuildHandoff.delete_all
      ActorProfile.delete_all
      Cluster.delete_all
    end
  end
end
