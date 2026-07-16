# frozen_string_literal: true

require "test_helper"

module ActorBehaviors
  class StrictHealthSnapshotTest < ActiveSupport::TestCase
    def setup
      ActorBehaviorSnapshot.delete_all
      ActorBehaviorBuildHandoff.delete_all
      ActorProfile.delete_all
      Address.delete_all
      Cluster.delete_all
    end

    test "reports certified coverage, stale data and durable backlog" do
      cluster = Cluster.create!(composition_version: 1, last_seen_height: 10)
      Address.create!(address: "health-#{SecureRandom.hex(8)}", cluster: cluster)
      profile = ActorProfile.create!(
        cluster: cluster, cluster_composition_version: 1,
        last_computed_height: 10, dirty: false,
        traits: { "profile_version" => "strict_v3_core" },
        metadata: { "strict" => true, "address_spend_projection_hash" => "h10" }
      )
      ActorBehaviorSnapshot.create!(
        cluster: cluster, actor_profile: profile,
        cluster_composition_version: 1, profile_version: "strict_v3_core",
        profile_height: 10, source_hash: "h10", profile_fingerprint: "fingerprint",
        behavior_version: "strict_v2", status: "certified",
        certification_scope: "strict", certified_at: Time.current,
        computed_at: Time.current
      )
      ActorBehaviorBuildHandoff.create!(
        cluster: cluster, actor_profile: profile,
        cluster_composition_version: 1, profile_version: "strict_v3_core",
        source_height: 10, source_hash: "h10"
      )

      snapshot = snapshot_with_sidekiq(
        available: true, queue_size: 0, queue_latency_seconds: 0.0,
        worker_count: 0, scheduled_count: 0
      )
      assert_equal 1, snapshot[:actor_profiles_eligible]
      assert_equal 1, snapshot[:actor_behaviors_certified]
      assert_equal 0, snapshot[:actor_behaviors_missing]
      assert_equal 1.0, snapshot[:coverage]
      assert snapshot[:automation_missing]

      profile.update_columns(last_computed_height: 11)
      stale = snapshot_with_sidekiq(
        available: true, queue_size: 1, queue_latency_seconds: 2.0,
        worker_count: 0, scheduled_count: 0
      )
      assert_equal 1, stale[:actor_behaviors_stale]
      refute stale[:automation_missing]
      assert JSON.generate(stale)
    end

    test "Sidekiq and PostgreSQL unavailability never become false zeros" do
      sidekiq = snapshot_with_sidekiq(
        available: false, queue_size: nil, queue_latency_seconds: nil,
        worker_count: nil, scheduled_count: nil
      )
      assert_equal "unavailable", sidekiq[:status]
      assert_nil sidekiq.dig(:sidekiq, :queue_size)
      refute sidekiq[:automation_missing]

      failure = -> { raise ActiveRecord::StatementInvalid, "database unavailable" }
      with_singleton_method(ActorProfiles::CertifiedScope, :call, failure) do
        database = StrictHealthSnapshot.call
        assert_equal "unavailable", database[:status]
        assert_nil database[:actor_profiles_eligible]
        assert_nil database[:handoffs]
      end
    end

    private

    def snapshot_with_sidekiq(metrics)
      instance = StrictHealthSnapshot.new(now: Time.current)
      with_singleton_method(instance, :sidekiq_metrics, -> { metrics }) { instance.call }
    end

    def with_singleton_method(target, method_name, replacement)
      singleton = target.singleton_class
      original = :"#{method_name}_without_health_test"
      singleton.alias_method(original, method_name)
      singleton.define_method(method_name, &replacement)
      yield
    ensure
      singleton.alias_method(method_name, original)
      singleton.remove_method(original)
    end
  end
end
