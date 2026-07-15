# frozen_string_literal: true

require "test_helper"

module Clusters
  class ActorProfileHandoffDispatcherTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    class SimulatedCrash < StandardError; end

    def setup
      cleanup!
      @height = 958_000 + SecureRandom.random_number(1_000)
      @hash = Digest::SHA256.hexdigest("dispatch-#{SecureRandom.hex(16)}")
      @cluster = Cluster.create!(address_count: 1, composition_version: 1)
      Address.create!(address: "dispatch-#{SecureRandom.hex(8)}", cluster: @cluster)
      BlockBufferModel.create!(height: @height, block_hash: @hash, status: "processed")
      ClusterProcessedBlock.create!(
        height: @height,
        block_hash: @hash,
        status: "processed",
        processed_at: Time.current
      )
    end

    def teardown
      cleanup!
    end

    test "claims in deterministic order and completes terminal ActorProfile results" do
      second = create_handoff!(height: @height + 1, block_hash: hash_for("second"))
      ClusterProcessedBlock.create!(
        height: second.cluster_height,
        block_hash: second.block_hash,
        status: "processed",
        processed_at: Time.current
      )
      first = create_handoff!
      statuses = %w[built already_current]
      calls = []
      actor = lambda do |cluster_id:, composition_version:|
        calls << [cluster_id, composition_version]
        { status: statuses.shift, ok: true }
      end

      with_actor_builder(actor) do
        result = ActorProfileHandoffDispatcher.call(limit: 2)
        assert_equal 2, result[:claimed]
        assert_equal 2, result[:completed]
      end

      assert_equal [first.id, second.id],
        ClusterActorProfileHandoff.order(:cluster_height, :cluster_id, :id).pluck(:id)
      assert_equal [[@cluster.id, 1], [@cluster.id, 1]], calls
      assert_equal %w[completed completed],
        ClusterActorProfileHandoff.order(:cluster_height).pluck(:status)
      assert_equal [1, 1], ClusterActorProfileHandoff.order(:cluster_height).pluck(:attempts)
    end

    test "a refused composition becomes failed without being completed" do
      handoff = create_handoff!
      actor = ->(**) { { status: "refused", ok: false, reason: "future_composition_version" } }

      with_actor_builder(actor) do
        result = ActorProfileHandoffDispatcher.call
        assert_equal 1, result[:failed]
        assert_equal "refused", result[:results].sole[:actor_profile_status]
      end
      assert_equal "failed", handoff.reload.status
      assert_equal "ActorProfileCompositionRefused", handoff.last_error_class
      assert_nil handoff.completed_at
    end

    test "missing failed or divergent checkpoints fail closed" do
      handoff = create_handoff!
      ClusterProcessedBlock.where(height: @height).delete_all
      assert_raises(ActorProfileHandoffDispatcher::InvalidCertification) do
        ActorProfileHandoffDispatcher.call
      end
      assert_equal "failed", handoff.reload.status

      handoff.update_columns(status: "pending", claimed_at: nil, attempts: 0, last_error_class: nil)
      ClusterProcessedBlock.create!(height: @height, block_hash: @hash, status: "failed")
      assert_raises(ActorProfileHandoffDispatcher::InvalidCertification) do
        ActorProfileHandoffDispatcher.call
      end

      ClusterProcessedBlock.where(height: @height).update_all(status: "processed", block_hash: "other")
      handoff.update_columns(status: "pending", claimed_at: nil, attempts: 0, last_error_class: nil)
      assert_raises(ActorProfileHandoffDispatcher::InvalidCertification) do
        ActorProfileHandoffDispatcher.call
      end
    end

    test "an ActorProfile exception is recorded then propagated unchanged" do
      handoff = create_handoff!
      error = SimulatedCrash.new("actor build crashed")

      with_actor_builder(->(**) { raise error }) do
        raised = assert_raises(SimulatedCrash) { ActorProfileHandoffDispatcher.call }
        assert_same error, raised
      end
      assert_equal "failed", handoff.reload.status
      assert_equal name_for(SimulatedCrash), handoff.last_error_class
      assert_equal 1, handoff.attempts
    end

    test "stale processing is reclaimed and completed while fresh processing is ignored" do
      stale = create_handoff!
      stale.update_columns(
        status: "processing",
        attempts: 1,
        claimed_at: 20.minutes.ago
      )
      fresh = create_handoff!(block_hash: @hash, composition_version: 2)
      fresh.update_columns(status: "processing", attempts: 1, claimed_at: 1.minute.ago)
      @cluster.update!(composition_version: 2)
      newer = create_handoff!(block_hash: hash_for("newer"), composition_version: 2, height: @height + 1)
      newer.update_columns(status: "completed", completed_at: Time.current)
      actor = ->(composition_version:, **) do
        { status: composition_version == 1 ? "superseded" : "built", ok: true }
      end

      with_actor_builder(actor) do
        result = ActorProfileHandoffDispatcher.call
        assert_equal 1, result[:claimed]
      end
      assert_equal "completed", stale.reload.status
      assert_equal 2, stale.attempts
      assert_equal "processing", fresh.reload.status
      assert_equal 1, fresh.attempts
    end

    test "completed and exhausted failed rows are never claimed" do
      completed = create_handoff!
      completed.claim!
      completed.complete!
      exhausted = create_handoff!(composition_version: 2)
      exhausted.update_columns(status: "failed", attempts: 5, last_error_class: "RuntimeError")

      result = ActorProfileHandoffDispatcher.call

      assert_equal 0, result[:claimed]
      assert_equal false, ActorProfileHandoffDispatcher.work_available?
    end

    test "FOR UPDATE SKIP LOCKED ignores a locked row and later recovers it" do
      handoff = create_handoff!
      locked = Queue.new
      release = Queue.new
      thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ApplicationRecord.transaction do
            ClusterActorProfileHandoff.lock.find(handoff.id)
            locked << true
            release.pop
          end
        end
      end
      locked.pop

      assert_equal 0, ActorProfileHandoffDispatcher.call[:claimed]
      release << true
      thread.join
      with_actor_builder(->(**) { { status: "built", ok: true } }) do
        assert_equal 1, ActorProfileHandoffDispatcher.call[:completed]
      end
    ensure
      release << true if release&.empty?
      thread&.join
    end

    test "two dispatchers never claim the same row" do
      handoff = create_handoff!
      entered = Queue.new
      release = Queue.new
      actor = lambda do |**|
        entered << true
        release.pop
        { status: "built", ok: true }
      end
      first = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          with_actor_builder(actor) { ActorProfileHandoffDispatcher.call }
        end
      end
      entered.pop
      second = ActorProfileHandoffDispatcher.call
      release << true
      first_result = first.value

      assert_equal 0, second[:claimed]
      assert_equal 1, first_result[:claimed]
      assert_equal 1, handoff.reload.attempts
      assert_equal "completed", handoff.status
    ensure
      release << true if release&.empty?
      first&.join
    end

    test "crash after ActorProfile commit but before completed replays as already current" do
      handoff = create_handoff!
      original_complete = ClusterActorProfileHandoff.instance_method(:complete!)
      first = true
      ClusterActorProfileHandoff.define_method(:complete!) do |at: Time.current|
        if first
          first = false
          raise SimulatedCrash, "completion crashed"
        end
        original_complete.bind_call(self, at: at)
      end

      assert_raises(SimulatedCrash) { ActorProfileHandoffDispatcher.call }
      assert_equal "failed", handoff.reload.status
      assert_equal 1, ActorProfile.where(cluster_id: @cluster.id).count
      result = ActorProfileHandoffDispatcher.call

      assert_equal "already_current", result[:results].sole[:actor_profile_status]
      assert_equal "completed", handoff.reload.status
      assert_equal 2, handoff.attempts
      assert_equal 1, ActorProfile.where(cluster_id: @cluster.id).count
    ensure
      ClusterActorProfileHandoff.define_method(:complete!, original_complete) if original_complete
    end

    test "empty result and work probe are PostgreSQL-only and JSON serializable" do
      sql = capture_sql do
        @available = ActorProfileHandoffDispatcher.work_available?
        @result = ActorProfileHandoffDispatcher.call
      end
      source = File.read(Rails.root.join("app/services/clusters/actor_profile_handoff_dispatcher.rb"))

      assert_equal false, @available
      assert_equal 0, @result[:claimed]
      assert JSON.generate(@result)
      assert_no_match(/Redis|Sidekiq/, source)
      assert_empty sql.grep(/redis|sidekiq/i)
    end

    test "leaves a handoff pending until the exact AddressSpend checkpoint is certified" do
      handoff = create_handoff!
      AddressSpendProjectionBlock.delete_all

      assert_equal false, ActorProfileHandoffDispatcher.work_available?
      assert_equal 0, ActorProfileHandoffDispatcher.call[:claimed]
      assert_equal "pending", handoff.reload.status

      AddressSpendProjectionBlock.create!(
        height: @height,
        block_hash: @hash,
        status: "completed",
        completed_at: Time.current
      )
      with_actor_builder(->(**) { { status: "built", ok: true } }) do
        assert_equal 1, ActorProfileHandoffDispatcher.call[:completed]
      end
    end

    private

    def create_handoff!(height: @height, block_hash: @hash, composition_version: 1)
      AddressSpendProjectionBlock.find_or_create_by!(height: height) do |checkpoint|
        checkpoint.block_hash = block_hash
        checkpoint.status = "completed"
        checkpoint.completed_at = Time.current
      end
      ClusterActorProfileHandoff.create!(
        cluster_height: height,
        block_hash: block_hash,
        cluster: @cluster,
        composition_version: composition_version
      )
    end

    def with_actor_builder(callable)
      original = ActorProfiles::StrictBuildFromCluster.method(:call)
      ActorProfiles::StrictBuildFromCluster.define_singleton_method(:call) do |**arguments|
        callable.call(**arguments)
      end
      yield
    ensure
      ActorProfiles::StrictBuildFromCluster.define_singleton_method(:call) do |**arguments|
        original.call(**arguments)
      end
    end

    def name_for(klass)
      klass.name
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
      ActorProfile.delete_all
      ClusterActorProfileHandoff.delete_all
      AddressSpendProjectionBlock.delete_all
      AddressSpendStat.delete_all
      Address.delete_all
      ClusterProcessedBlock.delete_all
      BlockBufferModel.delete_all
      Cluster.delete_all
    end
  end
end
