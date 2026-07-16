# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

module ActorLabels
  class BuildDispatcherCrashSafetyTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    def setup
      cleanup
      @cluster = Cluster.create!(composition_version: 1)
      @profile = ActorProfile.create!(cluster: @cluster)
      @snapshot = ActorBehaviorSnapshot.create!(
        cluster: @cluster, actor_profile: @profile,
        profile_version: "strict_v3_core", profile_height: 10,
        cluster_composition_version: 1, profile_fingerprint: "fp",
        behavior_version: "strict_v2", status: "certified",
        source_hash: "hash", certification_scope: "strict",
        certified_at: Time.current, computed_at: Time.current,
        signals: { "whale_like_candidate_inputs" => true },
        scores: { "whale_score" => 85 }
      )
      @handoff = ActorLabelHandoff.create!(
        cluster: @cluster, actor_behavior_snapshot: @snapshot,
        cluster_composition_version: 1, profile_version: "strict_v3_core",
        source_height: 10, source_hash: "hash", behavior_version: "strict_v2",
        rule_version: CertifiedRuleSet::RULE_VERSION
      )
    end

    def teardown = cleanup

    test "concurrent dispatchers claim one handoff exactly once" do
      ready = Queue.new
      release = Queue.new
      dispatchers = 2.times.map do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            dispatcher = BuildDispatcher.new(limit: 1, now: Time.current)
            ready << true
            release.pop
            dispatcher.send(:claim)
          end
        end
      end
      2.times { ready.pop }
      2.times { release << true }
      claims = dispatchers.map(&:value)

      assert_equal 1, claims.sum(&:size)
      assert_equal 1, @handoff.reload.attempts
      assert_equal "processing", @handoff.status
    ensure
      2.times { release << true } if defined?(release)
      dispatchers&.each(&:join)
    end

    test "a processing claim is invisible to another dispatcher" do
      first = ActiveRecord::Base.connection_pool.with_connection do
        BuildDispatcher.new(limit: 1, now: Time.current).send(:claim)
      end
      second = ActiveRecord::Base.connection_pool.with_connection do
        BuildDispatcher.new(limit: 1, now: Time.current).send(:claim)
      end

      assert_equal [@handoff.id], first.map(&:id)
      assert_empty second
      assert_equal 1, @handoff.reload.attempts
    end

    test "locked row is skipped then recovered after lock release" do
      locked = Queue.new
      release = Queue.new
      locker = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ApplicationRecord.transaction(requires_new: true) do
            ActorLabelHandoff.lock.find(@handoff.id)
            locked << true
            release.pop
          end
        end
      end
      locked.pop
      skipped = BuildDispatcher.call
      release << true
      locker.join
      recovered = nil
      StrictEvaluateFromBehavior.stub(:call, { status: "evaluated" }) do
        recovered = BuildDispatcher.call
      end

      assert_equal 0, skipped[:claimed]
      assert_equal 1, recovered[:claimed]
      assert_equal 1, @handoff.reload.attempts
    ensure
      release << true if defined?(release) && release.empty?
      locker&.join
    end

    test "stale and failed claims are recoverable but completed is not" do
      @handoff.update_columns(status: "processing", attempts: 1,
        claimed_at: 1.hour.ago)
      StrictEvaluateFromBehavior.stub(:call, { status: "evaluated" }) do
        BuildDispatcher.call
      end
      assert_equal 2, @handoff.reload.attempts
      assert_equal "completed", @handoff.status
      assert_equal 0, BuildDispatcher.call[:claimed]

      @handoff.update_columns(status: "failed", completed_at: nil)
      StrictEvaluateFromBehavior.stub(:call, { status: "evaluated" }) do
        BuildDispatcher.call
      end
      assert_equal 3, @handoff.reload.attempts
      assert_equal "completed", @handoff.status
    end

    test "crash after evaluation replays without duplicate strict labels" do
      assert_raises(RuntimeError) do
        with_instance_method(ActorLabelHandoff, :complete!, ->(**) { raise "completion crash" }) do
          BuildDispatcher.new(limit: 1, now: Time.current).call
        end
      end
      assert_equal 1, ActorLabelEvaluation.count
      assert_equal 1, ActorLabel.where(source: CertifiedRuleSet::SOURCE).count

      result = BuildDispatcher.new(limit: 1, now: Time.current).call
      assert_equal 1, result[:completed]
      assert_equal 1, ActorLabelEvaluation.count
      assert_equal 1, ActorLabel.where(source: CertifiedRuleSet::SOURCE).count
    end

    test "secondary failure never masks evaluator error and external labels survive" do
      manual = ActorLabel.create!(cluster: @cluster, label: "etf_like", source: "manual")
      error = Class.new(StandardError)
      with_instance_method(ActorLabelHandoff, :fail!, ->(**) { raise "failure persistence" }) do
        raised = assert_raises(error) do
          StrictEvaluateFromBehavior.stub(:call, ->(**) { raise error, "business" }) do
            BuildDispatcher.call
          end
        end
        assert_equal "business", raised.message
      end
      assert manual.reload
    end

    private

    def with_instance_method(klass, name, replacement)
      original = :"#{name}_without_crash_safety_test"
      klass.alias_method(original, name)
      klass.define_method(name, &replacement)
      yield
    ensure
      klass.alias_method(name, original)
      klass.remove_method(original)
    end

    def cleanup
      ActorLabelEvaluation.delete_all
      ActorLabelHandoff.delete_all
      ActorLabel.delete_all
      ActorBehaviorSnapshot.delete_all
      ActorProfile.delete_all
      Cluster.delete_all
    end
  end
end
