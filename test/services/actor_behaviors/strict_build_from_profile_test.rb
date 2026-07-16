# frozen_string_literal: true

require "test_helper"

module ActorBehaviors
  class StrictBuildFromProfileTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    def setup
      cleanup
      @cluster = Cluster.create!(composition_version: 2)
      @profile = ActorProfile.create!(
        cluster: @cluster,
        cluster_composition_version: 2,
        last_computed_height: 1_000,
        certification_epoch_height: 1_000,
        certification_scope: "strict",
        certified_at: Time.current,
        dirty: false,
        balance_btc: "1200",
        total_received_btc: "1500",
        total_sent_btc: "300",
        net_btc: "1200",
        tx_count: 250,
        inflow_count: 20,
        outflow_count: 10,
        traits: { "profile_version" => "strict_v3_core", "address_count" => 20 },
        metadata: {
          "strict" => true,
          "address_spend_projection_hash" => "source-1000"
        }
      )
      @handoff = ActorBehaviorBuildHandoff.create!(
        cluster: @cluster,
        actor_profile: @profile,
        cluster_composition_version: 2,
        profile_version: "strict_v3_core",
        source_height: 1_000,
        source_hash: "source-1000"
      )
      @arguments = {
        cluster_id: @cluster.id,
        cluster_composition_version: 2,
        profile_version: "strict_v3_core",
        source_height: 1_000,
        source_hash: "source-1000"
      }
    end

    def teardown
      cleanup
    end

    test "builds deterministic behavior from the exact certified profile" do
      result = StrictBuildFromProfile.call(**@arguments)
      snapshot = ActorBehaviorSnapshot.find(result.fetch(:snapshot_id))

      assert_equal "built", result[:status]
      assert_equal "strict_v2", snapshot.behavior_version
      assert_equal "strict", snapshot.certification_scope
      assert_equal "source-1000", snapshot.source_hash
      assert snapshot.certified_at
      assert_equal 85, snapshot.scores["whale_score"]
      assert_equal "large", snapshot.signals["holder_size"]
      assert JSON.generate(result)
      assert JSON.generate(snapshot.signals)
      assert JSON.generate(snapshot.scores)
      assert JSON.generate(snapshot.evidence)
    end

    test "replay is already current and preserves certification time" do
      first = StrictBuildFromProfile.call(**@arguments)
      certified_at = ActorBehaviorSnapshot.find(first[:snapshot_id]).certified_at

      second = StrictBuildFromProfile.call(**@arguments)

      assert_equal "already_current", second[:status]
      assert_equal certified_at, ActorBehaviorSnapshot.find(second[:snapshot_id]).certified_at
      assert_equal 1, ActorBehaviorSnapshot.where(cluster_id: @cluster.id).count
    end

    test "new certified source and new composition each produce a new build" do
      first = StrictBuildFromProfile.call(**@arguments)
      first_certified_at = ActorBehaviorSnapshot.find(first[:snapshot_id]).certified_at

      @profile.update!(
        last_computed_height: 1_001,
        certification_epoch_height: 1_001,
        certified_at: first_certified_at + 1.second,
        metadata: @profile.metadata.merge(
          "address_spend_projection_hash" => "source-1001"
        )
      )
      ActorBehaviorBuildHandoff.create!(
        cluster: @cluster,
        actor_profile: @profile,
        cluster_composition_version: 2,
        profile_version: "strict_v3_core",
        source_height: 1_001,
        source_hash: "source-1001"
      )

      newer_source = StrictBuildFromProfile.call(
        **@arguments.merge(source_height: 1_001, source_hash: "source-1001")
      )
      source_certified_at = ActorBehaviorSnapshot.find(newer_source[:snapshot_id]).certified_at

      @cluster.update!(composition_version: 3)
      @profile.update!(
        cluster_composition_version: 3,
        certified_at: source_certified_at + 1.second
      )
      ActorBehaviorBuildHandoff.create!(
        cluster: @cluster,
        actor_profile: @profile,
        cluster_composition_version: 3,
        profile_version: "strict_v3_core",
        source_height: 1_001,
        source_hash: "source-1001"
      )

      newer_composition = StrictBuildFromProfile.call(
        **@arguments.merge(
          cluster_composition_version: 3,
          source_height: 1_001,
          source_hash: "source-1001"
        )
      )

      assert_equal "built", newer_source[:status]
      assert_operator source_certified_at, :>, first_certified_at
      assert_equal "built", newer_composition[:status]
      assert_equal 3, ActorBehaviorSnapshot.find(newer_composition[:snapshot_id]).cluster_composition_version
      assert_equal 1, ActorBehaviorSnapshot.where(cluster_id: @cluster.id).count
    end

    test "concurrent identical requests materialize only once" do
      results = 2.times.map do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            StrictBuildFromProfile.call(**@arguments)
          end
        end
      end.map(&:value)

      assert_equal %w[already_current built], results.map { |result| result[:status] }.sort
      assert_equal 1, ActorBehaviorSnapshot.where(cluster_id: @cluster.id).count
    end

    test "future and uncertified profiles are refused" do
      future = StrictBuildFromProfile.call(
        **@arguments.merge(cluster_composition_version: 3)
      )
      @profile.update_columns(certified_at: nil)
      uncertified = StrictBuildFromProfile.call(**@arguments)

      assert_equal "refused", future[:status]
      assert_equal "future_profile_version", future[:reason]
      assert_equal "refused", uncertified[:status]
      assert_equal "profile_not_strictly_certified", uncertified[:reason]
      assert_equal 0, ActorBehaviorSnapshot.count
    end

    test "old version is superseded only with a newer durable handoff" do
      old = @arguments.merge(source_height: 999, source_hash: "source-999")
      @handoff.delete
      refused = StrictBuildFromProfile.call(**old)

      @cluster.update!(composition_version: 3)
      @profile.update_columns(cluster_composition_version: 3)
      ActorBehaviorBuildHandoff.create!(
        cluster: @cluster,
        actor_profile: @profile,
        cluster_composition_version: 3,
        profile_version: "strict_v3_core",
        source_height: 1_001,
        source_hash: "source-1001"
      )
      superseded = StrictBuildFromProfile.call(**old)

      assert_equal "refused", refused[:status]
      assert_equal "newer_handoff_missing", refused[:reason]
      assert_equal "superseded", superseded[:status]
      assert_equal "newer_durable_handoff", superseded[:reason]
    end

    test "persistence failure rolls back the snapshot" do
      builder = StrictBuildFromProfile.new(**@arguments)
      replacement = ->(*) { raise ActiveRecord::StatementInvalid, "snapshot failed" }

      assert_raises(ActiveRecord::StatementInvalid) do
        with_singleton_method(builder, :persist_snapshot!, replacement) { builder.call }
      end
      assert_equal 0, ActorBehaviorSnapshot.count
    end

    private

    def with_singleton_method(target, method_name, replacement)
      singleton = target.singleton_class
      original = :"#{method_name}_without_strict_build_test"
      singleton.alias_method(original, method_name)
      singleton.define_method(method_name, &replacement)
      yield
    ensure
      singleton.alias_method(method_name, original)
      singleton.remove_method(original)
    end

    def cleanup
      ActorLabelHandoff.delete_all
      ActorBehaviorSnapshot.delete_all
      ActorBehaviorBuildHandoff.delete_all
      ActorProfile.delete_all
      Cluster.delete_all
    end
  end
end
