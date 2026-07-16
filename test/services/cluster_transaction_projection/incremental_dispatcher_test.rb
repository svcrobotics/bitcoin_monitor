# frozen_string_literal: true

require "test_helper"

module ClusterTransactionProjection
  class IncrementalDispatcherTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    def setup
      @base_height = 2_500_000 + SecureRandom.random_number(100_000)
      @next_height = @base_height + 1
      @base_hash = txid("base-#{SecureRandom.hex(8)}")
      @next_hash = txid("next-#{SecureRandom.hex(8)}")
      @records = []
      @fixture = create_generation_fixture
    end

    def teardown
      ClusterTransactionFact.where(
        projection_generation_id: @records.filter_map { |entry| entry[:generation_id] }
      ).delete_all
      ClusterTransactionProjectionGeneration.where(
        id: @records.filter_map { |entry| entry[:generation_id] }
      ).delete_all
      ClusterTransactionProjectionBlock.where(
        block_height: [@base_height, @next_height, @next_height + 1]
      ).delete_all
      @records.each do |entry|
        ClusterInput.where(address: entry[:address]).delete_all
        UtxoOutput.where(address: entry[:address]).delete_all
        Address.where(address: entry[:address]).delete_all
      end
      ClusterProcessedBlock.where(
        height: [@base_height, @next_height, @next_height + 1]
      ).delete_all
      BlockBufferModel.where(
        height: [@base_height, @next_height, @next_height + 1]
      ).delete_all
      Cluster.where(id: @records.filter_map { |entry| entry[:cluster_id] }).delete_all
    end

    test "selects exactly checkpoint plus one and advances the generation" do
      received = txid("received")
      create_utxo(@fixture, received)

      result = IncrementalDispatcher.call(limit: 5)
      candidate = result.candidates.sole

      assert result.ok
      assert_equal :projected, candidate.status
      assert_equal @next_height, candidate.next_height
      assert_equal @next_hash, candidate.block_hash
      assert_equal 1, candidate.expected_composition_version
      assert_equal @next_height, generation.reload.checkpoint_height
      assert_equal received,
        Txid.unpack(generation.facts.find_by!(received_height: @next_height).txid)
    end

    test "never crosses a missing next height" do
      ClusterProcessedBlock.where(height: @next_height).delete_all
      create_cluster_checkpoint(@next_height + 1, txid("later"))

      result = IncrementalDispatcher.call(limit: 5)

      assert_equal :next_height_missing, result.candidates.sole.reason
      assert_equal @base_height, generation.reload.checkpoint_height
    end

    test "excludes changed compositions and noncanonical current checkpoints" do
      cluster.update!(composition_version: 2)
      result = IncrementalDispatcher.call(limit: 5)
      assert_equal :composition_changed, result.candidates.sole.reason

      cluster.update!(composition_version: 1)
      ClusterProcessedBlock.where(height: @base_height).update_all(
        block_hash: txid("wrong-current")
      )
      result = IncrementalDispatcher.call(limit: 5)
      assert_equal :checkpoint_not_canonical, result.candidates.sole.reason
      assert_equal @base_height, generation.reload.checkpoint_height
    end

    test "never selects stale or replaced generations" do
      generation.update!(status: "stale", stale_at: Time.current)
      assert_equal 0, IncrementalDispatcher.call(limit: 5).selected

      generation.update!(status: "replaced")
      assert_equal 0, IncrementalDispatcher.call(limit: 5).selected
    end

    test "reports reconstruction required without creating a replacement" do
      generation.update_column(:cluster_id, cluster.id + 10_000_000)

      result = IncrementalDispatcher.call(limit: 5)

      assert_equal :reconstruction_required, result.candidates.sole.reason
      assert_equal 1, ClusterTransactionProjectionGeneration.where(id: generation.id).count
    end

    test "reports an occupied advisory lock" do
      acquired = Queue.new
      release = Queue.new
      key = dispatcher.send(:advisory_lock_key, generation.id)
      holder = Thread.new do
        ApplicationRecord.connection_pool.with_connection do |connection|
          dispatcher.send(:advisory_lock, connection, key)
          acquired << true
          release.pop
          dispatcher.send(:advisory_unlock, connection, key)
        end
      end
      acquired.pop

      result = IncrementalDispatcher.call(limit: 5)

      assert_equal :advisory_lock_busy, result.candidates.sole.reason
      assert_equal @base_height, generation.reload.checkpoint_height
    ensure
      release << true if release
      holder&.value
    end

    test "releases the advisory lock after success and exception" do
      IncrementalDispatcher.call(limit: 5)
      assert_lock_available(generation.id)

      second = create_generation_fixture
      error = assert_raises(IncrementalDispatcher::BatchError) do
        with_stubbed_call(CertifiedBlockActivity, ->(**) { raise "activity failed" }) do
          IncrementalDispatcher.call(limit: 5)
        end
      end
      assert_equal 1, error.result.failed
      assert_lock_available(second[:generation].id)
    end

    test "two dispatchers do not process the same generation concurrently" do
      entered = Queue.new
      release = Queue.new
      first = dispatcher
      original = first.method(:process_locked_candidate)
      first.define_singleton_method(:process_locked_candidate) do |generation_id|
        entered << true
        release.pop
        original.call(generation_id)
      end

      thread = Thread.new { first.call }
      entered.pop
      concurrent = IncrementalDispatcher.call(limit: 5)
      release << true
      completed = thread.value

      assert_equal :advisory_lock_busy, concurrent.candidates.sole.reason
      assert_equal 1, completed.projected
      assert_equal @next_height, generation.reload.checkpoint_height
    end

    test "an apply race is replayed as already projected" do
      original = CertifiedBlockActivity.method(:call)
      raced = false
      wrapper = lambda do |**arguments|
        activity = original.call(**arguments)
        unless raced
          raced = true
          ApplyBlock.call(
            **arguments,
            received_txids: activity.received_txids,
            spent_txids: activity.spent_txids
          )
        end
        activity
      end

      result = with_stubbed_call(CertifiedBlockActivity, wrapper) do
        IncrementalDispatcher.call(limit: 5)
      end

      assert_equal 1, result.already_projected
      assert_equal :already_projected, result.candidates.sole.reason
      assert_equal 0, IncrementalDispatcher.call(limit: 5).selected
    end

    test "one candidate error does not mask later candidates" do
      second = create_generation_fixture
      original = CertifiedBlockActivity.method(:call)
      wrapper = lambda do |**arguments|
        raise "first candidate failed" if arguments[:cluster_id] == cluster.id

        original.call(**arguments)
      end

      error = assert_raises(IncrementalDispatcher::BatchError) do
        with_stubbed_call(CertifiedBlockActivity, wrapper) do
          IncrementalDispatcher.call(limit: 5)
        end
      end

      assert_equal false, error.result.ok
      assert_equal 1, error.result.failed
      assert_equal 1, error.result.projected
      assert_equal @base_height, generation.reload.checkpoint_height
      assert_equal @next_height, second[:generation].reload.checkpoint_height
    end

    test "contains no Redis Sidekiq or backfill dependency" do
      source = File.read(
        Rails.root.join(
          "app/services/cluster_transaction_projection/incremental_dispatcher.rb"
        )
      )

      refute_match(/Redis|Sidekiq|StrictIoLease|BackfillRunner|BackfillSliceJob/, source)
    end

    private

    def dispatcher
      IncrementalDispatcher.new(limit: 5)
    end

    def generation
      @fixture.fetch(:generation)
    end

    def cluster
      @fixture.fetch(:cluster)
    end

    def create_generation_fixture
      cluster = Cluster.create!(composition_version: 1)
      address = "ctp-dispatch-#{SecureRandom.hex(12)}"
      Address.create!(address: address, cluster: cluster)
      create_cluster_checkpoint(@base_height, @base_hash) unless
        ClusterProcessedBlock.exists?(height: @base_height)
      create_cluster_checkpoint(@next_height, @next_hash) unless
        ClusterProcessedBlock.exists?(height: @next_height)
      create_layer1_checkpoint(@next_height, @next_hash) unless
        BlockBufferModel.exists?(height: @next_height, block_hash: @next_hash)
      ClusterTransactionProjectionBlock.find_or_create_by!(
        block_height: @base_height
      ) do |block|
        block.block_hash = @base_hash
        block.status = "projected"
        block.completed_at = Time.current
      end

      generation = GenerationBuilder.call(
        cluster_id: cluster.id,
        composition_version: 1,
        checkpoint_height: @base_height,
        checkpoint_hash: @base_hash
      )
      assert Certifier.call(generation).ok

      record = {
        cluster: cluster,
        cluster_id: cluster.id,
        generation: generation,
        generation_id: generation.id,
        address: address
      }
      @records << record
      record
    end

    def create_cluster_checkpoint(height, hash)
      ClusterProcessedBlock.create!(
        height: height,
        block_hash: hash,
        status: "processed",
        processed_at: Time.current,
        audit_result: { "ok" => true }
      )
    end

    def create_layer1_checkpoint(height, hash)
      BlockBufferModel.create!(
        height: height,
        block_hash: hash,
        status: "processed",
        is_orphan: false,
        processed_at: Time.current,
        strict_metrics: {
          "outputs_audit_ok" => true,
          "inputs_audit_ok" => true,
          "utxo_audit_ok" => true
        }
      )
    end

    def create_utxo(fixture, txid_value)
      UtxoOutput.create!(
        txid: txid_value,
        vout: 0,
        address: fixture.fetch(:address),
        amount_btc: 1,
        block_height: @next_height,
        block_hash: @next_hash
      )
    end

    def assert_lock_available(generation_id)
      connection = ApplicationRecord.connection_pool.checkout
      key = dispatcher.send(:advisory_lock_key, generation_id)
      assert dispatcher.send(:advisory_lock, connection, key)
    ensure
      dispatcher.send(:advisory_unlock, connection, key) if connection && key
      ApplicationRecord.connection_pool.checkin(connection) if connection
    end

    def with_stubbed_call(target, replacement)
      original = target.method(:call)
      target.define_singleton_method(:call) do |*args, **kwargs, &block|
        replacement.call(*args, **kwargs, &block)
      end
      yield
    ensure
      target.define_singleton_method(:call) do |*args, **kwargs, &block|
        original.call(*args, **kwargs, &block)
      end
    end

    def txid(seed)
      Digest::SHA256.hexdigest(seed)
    end
  end
end
