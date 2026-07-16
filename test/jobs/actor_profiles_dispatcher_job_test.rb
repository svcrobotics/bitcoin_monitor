# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

class ActorProfilesDispatcherJobTest < ActiveSupport::TestCase
  FakeRedis = Struct.new(:members, :removed) do
    def srandmember(_key, count) = members.first(count)
    def srem(_key, values) = removed.concat(Array(values))
    def scard(_key) = members.size - removed.size
  end

  setup { @previous = ENV["ACTOR_PROFILE_REDIS_RECOVERY_ENABLED"] }
  teardown { ENV["ACTOR_PROFILE_REDIS_RECOVERY_ENABLED"] = @previous }

  test "is disabled by default without touching Redis" do
    ENV.delete("ACTOR_PROFILE_REDIS_RECOVERY_ENABLED")
    Redis.stub(:new, ->(**) { flunk "Redis must not be touched" }) do
      result = ActorProfilesDispatcherJob.perform_now
      assert_equal "legacy_recovery_disabled", result[:reason]
    end
  end

  test "removes legacy ids only after durable admission" do
    ENV["ACTOR_PROFILE_REDIS_RECOVERY_ENABLED"] = "1"
    redis = FakeRedis.new(%w[10 20], [])
    admission = { ok: true, selected: 1, created: 1, already_registered: 0,
      registered_cluster_ids: [10] }
    Redis.stub(:new, redis) do
      ActorProfiles::Admission.stub(:register_latest, admission) do
        result = ActorProfilesDispatcherJob.perform_now(batch_size: 2)
        assert_equal [10], redis.removed
        assert_equal 1, result[:imported]
        assert_equal 1, result[:remaining]
      end
    end
  end

  test "a PostgreSQL failure leaves every Redis member untouched" do
    ENV["ACTOR_PROFILE_REDIS_RECOVERY_ENABLED"] = "1"
    redis = FakeRedis.new(%w[10], [])
    error = ActiveRecord::StatementInvalid.new("database unavailable")
    Redis.stub(:new, redis) do
      ActorProfiles::Admission.stub(:register_latest, ->(**) { raise error }) do
        raised = assert_raises(ActiveRecord::StatementInvalid) do
          ActorProfilesDispatcherJob.perform_now(batch_size: 1)
        end
        assert_same error, raised
      end
    end
    assert_empty redis.removed
  end
end
