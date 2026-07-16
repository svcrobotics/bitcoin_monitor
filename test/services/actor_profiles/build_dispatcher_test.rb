# frozen_string_literal: true

require "test_helper"

module ActorProfiles
  class BuildDispatcherTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    setup do
      cleanup!
      @height = 1_800_001
      @hash = "dispatch-source"
      @cluster = Cluster.create!(composition_version: 1)
      ClusterProcessedBlock.create!(height: @height, block_hash: @hash,
        status: "processed", processed_at: Time.current)
      AddressSpendProjectionBlock.create!(height: @height, block_hash: @hash,
        status: "completed", completed_at: Time.current)
    end

    teardown { cleanup! }

    test "claims deterministically and completes safe terminal results" do
      first = admission!(height: @height)
      ClusterProcessedBlock.create!(height: @height + 1, block_hash: "next",
        status: "processed", processed_at: Time.current)
      AddressSpendProjectionBlock.create!(height: @height + 1, block_hash: "next",
        status: "completed", completed_at: Time.current)
      second = admission!(height: @height + 1, hash: "next")
      calls = []
      builder = lambda do |**args|
        calls << args
        { ok: true, status: calls.one? ? "built" : "already_current" }
      end
      StrictBuildFromCluster.stub(:call, builder) do
        result = BuildDispatcher.call(limit: 2)
        assert_equal 2, result[:claimed]
        assert_equal 2, result[:completed]
      end
      assert_equal [first.id, second.id], ActorProfileBuildAdmission.order(:source_height).pluck(:id)
      assert_equal [@height, @height + 1], calls.pluck(:source_height)
      assert_equal %w[completed completed], ActorProfileBuildAdmission.order(:source_height).pluck(:status)
    end

    test "refused fails and exceptions remain retryable" do
      refused = admission!
      StrictBuildFromCluster.stub(:call, { ok: false, status: "refused", reason: "hash" }) do
        assert_equal 1, BuildDispatcher.call[:failed]
      end
      assert_equal "failed", refused.reload.status

      refused.update_columns(status: "pending", attempts: 0, last_error_class: nil)
      error = RuntimeError.new("build crash")
      StrictBuildFromCluster.stub(:call, ->(**) { raise error }) do
        assert_same error, assert_raises(RuntimeError) { BuildDispatcher.call }
      end
      assert_equal "failed", refused.reload.status
      assert_equal "RuntimeError", refused.last_error_class
    end

    test "stale claims recover and completed rows never replay" do
      stale = admission!
      stale.update_columns(status: "processing", attempts: 1, claimed_at: 20.minutes.ago)
      completed = admission!(height: @height + 1, hash: "completed")
      completed.claim!
      completed.complete!
      StrictBuildFromCluster.stub(:call, { ok: true, status: "already_current" }) do
        assert_equal 1, BuildDispatcher.call[:claimed]
      end
      assert_equal 2, stale.reload.attempts
      assert_equal "completed", completed.reload.status
    end

    test "SKIP LOCKED leaves a locked admission for the next invocation" do
      admission = admission!
      locked = Queue.new
      release = Queue.new
      thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ApplicationRecord.transaction do
            ActorProfileBuildAdmission.lock.find(admission.id)
            locked << true
            release.pop
          end
        end
      end
      locked.pop
      assert_equal 0, BuildDispatcher.call[:claimed]
      release << true
      thread.join
      StrictBuildFromCluster.stub(:call, { ok: true, status: "built" }) do
        assert_equal 1, BuildDispatcher.call[:completed]
      end
    ensure
      release << true if release&.empty?
      thread&.join
    end


    test "imports an existing certified Cluster handoff before claiming it" do
      handoff = ClusterActorProfileHandoff.create!(cluster: @cluster,
        cluster_height: @height, block_hash: @hash, composition_version: 1)
      StrictBuildFromCluster.stub(:call, { ok: true, status: "built" }) do
        result = BuildDispatcher.call
        assert_equal 1, result[:imported_cluster_handoffs]
        assert_equal 1, result[:completed]
      end
      assert_equal "completed", handoff.reload.status
      assert ActorProfileBuildAdmission.exists?(cluster: @cluster,
        source_height: @height, source_hash: @hash)
    end

    private

    def admission!(height: @height, hash: @hash)
      ActorProfileBuildAdmission.create!(cluster: @cluster, cluster_composition_version: 1,
        source_height: height, source_hash: hash, reason: "address_spend")
    end

    def cleanup!
      ActorProfileBuildAdmission.delete_all
      ActorProfile.delete_all
      AddressSpendProjectionBlock.delete_all
      ClusterActorProfileHandoff.delete_all
      ClusterProcessedBlock.delete_all
      Address.delete_all
      Cluster.delete_all
    end
  end
end
