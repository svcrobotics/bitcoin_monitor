# frozen_string_literal: true

require "test_helper"

module ActorProfiles
  class StrictBuildFromClusterVersionedTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    def setup
      cleanup!
      @height = 956_000 + SecureRandom.random_number(1_000)
      @cluster = Cluster.create!(
        address_count: 1,
        first_seen_height: @height - 2,
        last_seen_height: @height - 1,
        composition_version: 3
      )
      Address.create!(address: "versioned-#{SecureRandom.hex(8)}", cluster: @cluster)
      BlockBufferModel.create!(height: @height, block_hash: hash_for("layer1"), status: "processed")
      @cluster_hash = hash_for("cluster")
      ClusterProcessedBlock.create!(
        height: @height,
        block_hash: @cluster_hash,
        status: "processed",
        processed_at: Time.current
      )
      AddressSpendProjectionBlock.create!(
        height: @height,
        block_hash: @cluster_hash,
        status: "completed",
        completed_at: Time.current
      )
    end

    def teardown
      cleanup!
    end

    test "builds exactly the requested locked composition and then is already current" do
      first = build(version: 3)
      first_certified_at = ActorProfile.find(first[:profile_id]).certified_at
      second = build(version: 3)

      assert_equal "built", first[:status]
      assert_equal false, first[:legacy]
      assert_equal 3, ActorProfile.find(first[:profile_id]).cluster_composition_version
      assert_equal "already_current", second[:status]
      assert_equal first[:profile_id], second[:profile_id]
      assert_equal 1, ActorProfile.where(cluster_id: @cluster.id).count
      assert first_certified_at.present?
      assert_equal first_certified_at,
        ActorProfile.find(first[:profile_id]).certified_at
      assert JSON.generate(first)
      assert JSON.generate(second)
    end

    test "a newer composition receives a later certification timestamp" do
      travel_to(Time.utc(2026, 7, 16, 10, 0, 0)) do
        first = build(version: 3)
        @first_certified_at = ActorProfile.find(first[:profile_id]).certified_at
      end

      Cluster.where(id: @cluster.id).update_all(composition_version: 4)

      travel_to(Time.utc(2026, 7, 16, 10, 1, 0)) do
        second = build(version: 4)
        profile = ActorProfile.find(second[:profile_id])

        assert_equal "built", second[:status]
        assert_operator profile.certified_at, :>, @first_certified_at
        assert_equal 4, profile.cluster_composition_version
      end
    end

    test "an incomplete same-version profile is rebuilt and certified" do
      profile = ActorProfile.create!(
        cluster: @cluster,
        cluster_composition_version: 3,
        last_computed_height: @height,
        dirty: true,
        traits: { profile_version: StrictBuildFromCluster::PROFILE_VERSION },
        metadata: { strict: true }
      )

      result = build(version: 3)
      profile.reload

      assert_equal "built", result[:status]
      assert_not profile.dirty?
      assert profile.certified_at.present?
    end

    test "strictly validates identifiers and requested versions" do
      [nil, 0, -1, "invalid", 1.2].each do |value|
        assert_raises(ArgumentError) do
          StrictBuildFromCluster.call(cluster_id: @cluster.id, composition_version: value)
        end
      end
      [nil, 0, -1, "invalid", 1.2].each do |value|
        assert_raises(ArgumentError) do
          StrictBuildFromCluster.call(cluster_id: value, composition_version: 3)
        end
      end
    end

    test "refuses a future version without replacing it by the current version" do
      result = build(version: 4)

      assert_equal false, result[:ok]
      assert_equal "refused", result[:status]
      assert_equal "future_composition_version", result[:reason]
      assert_equal 4, result[:requested_composition_version]
      assert_equal 3, result[:cluster_composition_version]
      assert_nil ActorProfile.find_by(cluster_id: @cluster.id)
    end

    test "supersedes an old version only when a newer durable admission exists" do
      without_handoff = build(version: 2)
      create_admission!(composition_version: 3)
      with_handoff = build(version: 2)

      assert_equal "refused", without_handoff[:status]
      assert_equal "newer_admission_missing", without_handoff[:reason]
      assert_equal "superseded", with_handoff[:status]
      assert_equal "newer_durable_admission", with_handoff[:reason]
      assert_nil ActorProfile.find_by(cluster_id: @cluster.id)
    end

    test "two concurrent calls serialize to one build and one already current result" do
      entered = Queue.new
      release = Queue.new
      original = StrictBuildFromCluster.instance_method(:compute_source_stats)
      first_call = true
      mutex = Mutex.new
      StrictBuildFromCluster.define_method(:compute_source_stats) do |cluster|
        wait = mutex.synchronize do
          selected = first_call
          first_call = false
          selected
        end
        if wait
          entered << true
          release.pop
        end
        original.bind_call(self, cluster)
      end

      first = Thread.new { ActiveRecord::Base.connection_pool.with_connection { build(version: 3) } }
      entered.pop
      second = Thread.new { ActiveRecord::Base.connection_pool.with_connection { build(version: 3) } }
      sleep 0.05
      release << true
      results = [first.value, second.value]

      assert_equal %w[already_current built], results.pluck(:status).sort
      assert_equal 1, ActorProfile.where(cluster_id: @cluster.id).count
    ensure
      release << true if release&.empty?
      first&.join
      second&.join
      StrictBuildFromCluster.define_method(:compute_source_stats, original) if original
    end

    test "a composition race is detected from the version locked after waiting" do
      connection = ActiveRecord::Base.connection
      connection.select_value(
        "SELECT pg_advisory_lock(#{StrictBuildFromCluster::ADVISORY_LOCK_NAMESPACE}, #{@cluster.id})"
      )
      thread = Thread.new { ActiveRecord::Base.connection_pool.with_connection { build(version: 3) } }
      Cluster.where(id: @cluster.id).update_all(composition_version: 4)
      connection.select_value(
        "SELECT pg_advisory_unlock(#{StrictBuildFromCluster::ADVISORY_LOCK_NAMESPACE}, #{@cluster.id})"
      )
      result = thread.value

      assert_equal "refused", result[:status]
      assert_equal 3, result[:requested_composition_version]
      assert_equal 4, result[:cluster_composition_version]
      assert_nil ActorProfile.find_by(cluster_id: @cluster.id)
    ensure
      connection&.select_value(
        "SELECT pg_advisory_unlock(#{StrictBuildFromCluster::ADVISORY_LOCK_NAMESPACE}, #{@cluster.id})"
      )
      thread&.join
    end

    test "an intermediate failure rolls back profile and materialized version" do
      original = StrictBuildFromCluster.instance_method(:compute_scores)
      StrictBuildFromCluster.define_method(:compute_scores) { |_stats| raise "score failure" }

      error = assert_raises(RuntimeError) { build(version: 3) }
      assert_equal "score failure", error.message
      assert_nil ActorProfile.find_by(cluster_id: @cluster.id)
    ensure
      StrictBuildFromCluster.define_method(:compute_scores, original) if original
    end

    test "a second connection sees certification only after the build commits" do
      reached_scores = Queue.new
      release_scores = Queue.new
      original = StrictBuildFromCluster.instance_method(:compute_scores)
      StrictBuildFromCluster.define_method(:compute_scores) do |stats|
        scores = original.bind_call(self, stats)
        reached_scores << true
        release_scores.pop
        scores
      end

      thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection { build(version: 3) }
      end
      reached_scores.pop

      ApplicationRecord.uncached do
        assert_nil ActorProfile.find_by(cluster_id: @cluster.id)
      end

      release_scores << true
      result = thread.value

      profile = ActorProfile.find(result[:profile_id])
      assert profile.certified_at.present?
      assert_equal true, profile.metadata["strict"]
      assert_not profile.dirty?
    ensure
      release_scores << true if release_scores&.empty?
      thread&.join
      StrictBuildFromCluster.define_method(:compute_scores, original) if original
    end

    test "legacy calls use the locked version explicitly and identify the compatibility path" do
      result = StrictBuildFromCluster.call(cluster_id: @cluster.id)

      assert_equal "built", result[:status]
      assert_equal true, result[:legacy]
      assert_equal 3, result[:cluster_composition_version]
      assert_equal 3, ActorProfile.find(result[:profile_id]).cluster_composition_version
    end

    test "versioned idempotence has no Redis or Sidekiq effect" do
      sql = capture_sql { @result = build(version: 3) }
      source = File.read(Rails.root.join("app/services/actor_profiles/strict_build_from_cluster.rb"))

      assert_no_match(/Redis|Sidekiq|perform_(?:async|later|in)/, source)
      assert_empty sql.grep(/redis|sidekiq/i)
      assert JSON.generate(@result)
    end

    test "a newer certified fact version rebuilds an unchanged composition" do
      first = build(version: 3)
      first_certified_at = ActorProfile.find(first[:profile_id]).certified_at
      newer_height = @height + 1
      newer_hash = hash_for("newer-source")
      BlockBufferModel.create!(height: newer_height, block_hash: newer_hash, status: "processed")
      ClusterProcessedBlock.create!(height: newer_height, block_hash: newer_hash,
        status: "processed", processed_at: Time.current)
      AddressSpendProjectionBlock.create!(height: newer_height, block_hash: newer_hash,
        status: "completed", completed_at: Time.current)
      ActorProfileBuildAdmission.create!(cluster: @cluster, cluster_composition_version: 3,
        source_height: newer_height, source_hash: newer_hash, reason: "address_spend")

      travel 1.second do
        second = StrictBuildFromCluster.call(cluster_id: @cluster.id, composition_version: 3,
          source_height: newer_height, source_hash: newer_hash)
        profile = ActorProfile.find(second[:profile_id])
        assert_equal "built", second[:status]
        assert_equal newer_height, profile.last_computed_height
        assert_equal newer_hash, profile.metadata["address_spend_projection_hash"]
        assert_operator profile.certified_at, :>, first_certified_at
      end
    end

    test "an old source is superseded only by a durable newer admission" do
      newer_height = @height + 1
      newer_hash = hash_for("durable-newer")
      BlockBufferModel.create!(height: newer_height, block_hash: newer_hash, status: "processed")
      ClusterProcessedBlock.create!(height: newer_height, block_hash: newer_hash,
        status: "processed", processed_at: Time.current)
      AddressSpendProjectionBlock.create!(height: newer_height, block_hash: newer_hash,
        status: "completed", completed_at: Time.current)

      refused = build(version: 3)
      ActorProfileBuildAdmission.create!(cluster: @cluster, cluster_composition_version: 3,
        source_height: newer_height, source_hash: newer_hash, reason: "address_spend")
      superseded = build(version: 3)

      assert_equal "refused", refused[:status]
      assert_equal "newer_admission_missing", refused[:reason]
      assert_equal "superseded", superseded[:status]
      assert_equal "newer_durable_admission", superseded[:reason]
    end

    test "requires the exact AddressSpend height and hash without accepting an ahead checkpoint" do
      AddressSpendProjectionBlock.delete_all
      error = assert_raises(ActorProfiles::DeferredSnapshotError) { build(version: 3) }
      assert_equal "address_spend_projection_not_ready", error.reason

      AddressSpendProjectionBlock.create!(
        height: @height + 1,
        block_hash: hash_for("ahead"),
        status: "completed",
        completed_at: Time.current
      )
      error = assert_raises(ActorProfiles::DeferredSnapshotError) { build(version: 3) }
      assert_equal @height + 1, error.details[:projection_tip]

      AddressSpendProjectionBlock.delete_all
      AddressSpendProjectionBlock.create!(
        height: @height,
        block_hash: "divergent",
        status: "completed",
        completed_at: Time.current
      )
      error = assert_raises(ActorProfiles::DeferredSnapshotError) { build(version: 3) }
      assert_equal false, error.details[:checkpoint_hash_matches]
    end

    private

    def build(version:)
      StrictBuildFromCluster.call(cluster_id: @cluster.id, composition_version: version,
        source_height: @height, source_hash: @cluster_hash)
    end

    def create_admission!(composition_version:)
      ActorProfileBuildAdmission.create!(cluster: @cluster,
        cluster_composition_version: composition_version, source_height: @height,
        source_hash: @cluster_hash, reason: "cluster_composition")
    end

    def create_handoff!(composition_version:)
      ClusterActorProfileHandoff.create!(
        cluster_height: @height,
        block_hash: hash_for("handoff"),
        cluster: @cluster,
        composition_version: composition_version
      )
    end

    def hash_for(prefix)
      Digest::SHA256.hexdigest("#{prefix}-#{SecureRandom.hex(16)}")
    end

    def capture_sql
      statements = []
      subscriber = lambda do |_name, _start, _finish, _id, payload|
        statements << payload[:sql].to_s unless payload[:name] == "SCHEMA"
      end
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
      statements
    end

    def cleanup!
      ActorLabel.delete_all
      ActorBehaviorBuildHandoff.delete_all
      ActorProfile.delete_all
      ActorProfileBuildAdmission.delete_all
      ClusterActorProfileHandoff.delete_all
      ClusterInput.delete_all
      AddressSpendStat.delete_all
      AddressSpendProjectionBlock.delete_all
      UtxoOutput.delete_all
      Address.delete_all
      ClusterProcessedBlock.delete_all
      BlockBufferModel.delete_all
      Cluster.delete_all
    end
  end
end
