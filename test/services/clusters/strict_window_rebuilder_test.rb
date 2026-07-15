# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

module Clusters
  class StrictWindowRebuilderTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    class SimulatedCrash < StandardError; end

    def setup
      cleanup!
      @height = 930_000 + SecureRandom.random_number(1_000)
      @block_hash = "cluster-atomic-#{SecureRandom.hex(16)}"
      BlockBufferModel.create!(
        height: @height,
        block_hash: @block_hash,
        status: "processed"
      )
      create_inputs!(height: @height)
    end

    def teardown
      cleanup!
    end

    test "scanner audit and processed checkpoint commit atomically" do
      isolation = nil
      original = Clusters::AuditBlock.method(:call)
      audit = lambda do |height:|
        isolation = ApplicationRecord.connection.select_value("SHOW transaction_isolation")
        original.call(height: height)
      end
      result = with_audit(audit) { rebuild }
      checkpoint = ClusterProcessedBlock.find_by!(height: @height)

      assert_equal "processed", checkpoint.status
      assert checkpoint.processed_at.present?
      assert_equal @block_hash, checkpoint.block_hash
      assert_equal "processed", result[:status]
      assert_equal @height, result[:height]
      assert_equal @block_hash, result[:block_hash]
      assert_equal result[:scanner][:clusters_touched], result[:clusters_touched]
      assert_equal "repeatable read", isolation
      assert JSON.generate(result)
    end

    test "a second connection sees neither mutations nor processing checkpoint before commit" do
      reached_audit = Queue.new
      release_audit = Queue.new
      original = Clusters::AuditBlock.method(:call)
      Clusters::AuditBlock.define_singleton_method(:call) do |height:|
        reached_audit << true
        release_audit.pop
        original.call(height: height)
      end

      thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection { rebuild }
      end
      reached_audit.pop

      ApplicationRecord.uncached do
        assert_equal 0, Address.where(address: input_addresses).count
        assert_equal 0, AddressLink.where(block_height: @height).count
        assert_equal 0, Cluster.joins(:addresses).where(addresses: { address: input_addresses }).count
        assert_nil ClusterProcessedBlock.find_by(height: @height)
      end

      release_audit << true
      result = thread.value
      ApplicationRecord.uncached do
        assert_equal 2, Address.where(address: input_addresses).count
        assert_equal 1, AddressLink.where(block_height: @height).count
        assert_equal 1, Cluster.joins(:addresses).where(addresses: { address: input_addresses }).distinct.count
        assert_equal "processed", ClusterProcessedBlock.find_by!(height: @height).status
      end
      assert_equal "processed", result[:status]
    ensure
      release_audit << true if release_audit&.empty?
      thread&.join
      Clusters::AuditBlock.define_singleton_method(:call) { |height:| original.call(height: height) } if original
    end

    test "negative audit rolls back Cluster mutations before writing failed checkpoint" do
      failure = healthy_audit.merge(ok: false, missing_links: 1)

      with_audit(failure) do
        assert_raises(StrictWindowRebuilder::AuditFailed) { rebuild }
      end

      assert_cluster_mutations_rolled_back
      assert_equal "failed", ClusterProcessedBlock.find_by!(height: @height).status
    end

    test "scanner exception rolls back all mutations" do
      failing_scanner = lambda do |height:, **|
        Address.create!(address: "transient-scanner-address")
        raise SimulatedCrash, "scanner interrupted"
      end

      with_scanner(failing_scanner) do
        error = assert_raises(SimulatedCrash) { rebuild }
        assert_equal "scanner interrupted", error.message
      end

      assert_nil Address.find_by(address: "transient-scanner-address")
      assert_equal "failed", ClusterProcessedBlock.find_by!(height: @height).status
    end

    test "audit exception rolls back scanner changes" do
      with_audit(->(**) { raise SimulatedCrash, "audit interrupted" }) do
        assert_raises(SimulatedCrash) { rebuild }
      end

      assert_cluster_mutations_rolled_back
      assert_equal "failed", ClusterProcessedBlock.find_by!(height: @height).status
    end

    test "mark processed exception rolls back scanner and checkpoint processing" do
      service = build_service
      service.stub(:mark_processed!, ->(*) { raise SimulatedCrash, "mark failed" }) do
        assert_raises(SimulatedCrash) { service.call }
      end

      assert_cluster_mutations_rolled_back
      assert_equal "failed", ClusterProcessedBlock.find_by!(height: @height).status
    end

    test "failed checkpoint persistence error does not mask original error" do
      service = build_service
      service.stub(:persist_failed_checkpoint, ->(**) { raise "failed persistence" }) do
        with_audit(->(**) { raise SimulatedCrash, "original audit error" }) do
          error = assert_raises(SimulatedCrash) { service.call }
          assert_equal "original audit error", error.message
        end
      end
    end

    test "same height and hash is idempotent after commit" do
      first = rebuild
      counts = [Address.count, Cluster.count, AddressLink.count]
      versions = Cluster.order(:id).pluck(:id, :composition_version)
      second = rebuild

      assert_equal "processed", first[:status]
      assert second[:skipped]
      assert_equal "already_processed", second[:reason]
      assert_equal counts, [Address.count, Cluster.count, AddressLink.count]
      assert_equal versions, Cluster.order(:id).pluck(:id, :composition_version)
    end

    test "processed checkpoint with divergent hash is refused without mutation" do
      ClusterProcessedBlock.create!(
        height: @height,
        block_hash: "different-hash",
        status: "processed",
        processed_at: Time.current
      )

      assert_raises(StrictWindowRebuilder::CheckpointHashMismatch) { rebuild }
      assert_cluster_mutations_rolled_back
      assert_equal "different-hash", ClusterProcessedBlock.find_by!(height: @height).block_hash
    end

    test "non processed Layer1 block is refused" do
      BlockBufferModel.where(height: @height).update_all(status: "pending")

      assert_raises(StrictWindowRebuilder::Layer1BlockUnavailable) { rebuild }
      assert_cluster_mutations_rolled_back
      assert_equal "failed", ClusterProcessedBlock.find_by!(height: @height).status
    end

    test "concurrent BlockBuffer hash change is detected under row lock" do
      service = build_service
      original_hash = @block_hash
      replacement = "replacement-#{SecureRandom.hex(12)}"
      expectation = lambda do |_height|
        BlockBufferModel.where(height: @height).update_all(block_hash: replacement)
        original_hash
      end

      service.stub(:expected_block_hash!, expectation) do
        assert_raises(StrictWindowRebuilder::BlockHashChanged) { service.call }
      end

      assert_cluster_mutations_rolled_back
      assert_equal "failed", ClusterProcessedBlock.find_by!(height: @height).status
    end

    test "rejects an encompassing transaction instead of accepting a savepoint" do
      error = assert_raises(StrictWindowRebuilder::EnclosingTransactionError) do
        ApplicationRecord.transaction { rebuild }
      end

      assert_match(/top-level PostgreSQL transaction/, error.message)
      assert_nil ClusterProcessedBlock.find_by(height: @height)
    end

    test "guard refusal before a height is mutation free and guard errors fail closed" do
      denied = StrictWindowRebuilder.call(
        from_height: @height,
        to_height: @height,
        yield_guard: ->(_height) { { allowed: false } }
      )

      assert_equal "preempted", denied[:status]
      assert_cluster_mutations_rolled_back
      assert_raises(StrictWindowRebuilder::GuardFailed) do
        StrictWindowRebuilder.call(
          from_height: @height,
          to_height: @height,
          yield_guard: ->(_height) { raise "guard unavailable" }
        )
      end
      assert_cluster_mutations_rolled_back
    end

    test "crash before commit rolls back and a subsequent run resumes" do
      with_audit(->(**) { raise SimulatedCrash, "crash before commit" }) do
        assert_raises(SimulatedCrash) { rebuild }
      end
      assert_cluster_mutations_rolled_back
      assert_equal "failed", ClusterProcessedBlock.find_by!(height: @height).status

      resumed = rebuild
      assert_equal "processed", resumed[:status]
      assert_equal 2, Address.where(address: input_addresses).count
      assert_equal 1, AddressLink.where(block_height: @height).count
    end

    test "transaction contains no external system or Layer1 projection access" do
      sql = capture_sql { @result = rebuild }
      source = File.read(Rails.root.join("app/services/clusters/strict_window_rebuilder.rb"))

      refute_match(/Redis|Sidekiq|BitcoinRpc|perform_(?:later|async|in)/, source)
      refute_match(/ActorProfile|ActorLabel|ActorBehavior|DirtyCluster/, source)
      refute_match(/tx_outputs|utxo_outputs/, source)
      assert_empty sql.grep(/\b(?:tx_outputs|utxo_outputs)\b/i)
      assert_empty sql.grep(/\A\s*(?:UPDATE|INSERT\s+INTO|DELETE\s+FROM)\s+\"?cluster_inputs\b/i)
      assert JSON.generate(@result)
    end

    test "reports measured transaction duration and releases row locks" do
      result = rebuild

      assert_kind_of Integer, result[:transaction_duration_ms]
      assert_operator result[:transaction_duration_ms], :>=, 0
      assert_no_row_locks_for_current_connection
    end

    private

    def rebuild
      build_service.call
    end

    def build_service
      StrictWindowRebuilder.new(from_height: @height, to_height: @height)
    end

    def healthy_audit
      {
        ok: true,
        height: @height,
        processed_txs: 1,
        processed_inputs: 2,
        issues: []
      }
    end

    def with_audit(callable)
      original = Clusters::AuditBlock.method(:call)
      replacement = callable.respond_to?(:call) ? callable : ->(**) { callable }
      Clusters::AuditBlock.define_singleton_method(:call) { |**arguments| replacement.call(**arguments) }
      yield
    ensure
      Clusters::AuditBlock.define_singleton_method(:call) { |**arguments| original.call(**arguments) }
    end

    def with_scanner(callable)
      original = ClusterScanner.method(:call)
      ClusterScanner.define_singleton_method(:call) { |**arguments| callable.call(**arguments) }
      yield
    ensure
      ClusterScanner.define_singleton_method(:call) { |**arguments| original.call(**arguments) }
    end

    def create_inputs!(height:)
      input_addresses.each_with_index do |address, index|
        ClusterInput.create!(
          block_height: height - 1,
          txid: "source-#{height}-#{index}",
          vout: index,
          address: address,
          amount_btc: "1.00000000",
          spent: true,
          spent_txid: "spend-#{height}",
          spent_block_height: height
        )
      end
    end

    def input_addresses
      @input_addresses ||= ["atomic-a-#{SecureRandom.hex(6)}", "atomic-b-#{SecureRandom.hex(6)}"]
    end

    def assert_cluster_mutations_rolled_back
      assert_equal 0, Address.where(address: input_addresses).count
      assert_equal 0, AddressLink.where(block_height: @height).count
      assert_equal 0, Cluster.joins(:addresses).where(addresses: { address: input_addresses }).count
    end

    def capture_sql
      statements = []
      subscriber = lambda do |_name, _start, _finish, _id, payload|
        statements << payload[:sql].to_s unless payload[:name] == "SCHEMA"
      end
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
      statements
    end

    def assert_no_row_locks_for_current_connection
      count = ApplicationRecord.connection.select_value(<<~SQL).to_i
        SELECT COUNT(*)
        FROM pg_locks
        WHERE pid = pg_backend_pid()
          AND locktype IN ('tuple', 'transactionid')
          AND granted
      SQL
      assert_equal 0, count
    end

    def cleanup!
      AddressLink.delete_all
      ClusterInput.delete_all
      Address.delete_all
      ClusterProcessedBlock.delete_all
      BlockBufferModel.delete_all
      Cluster.delete_all
    end
  end
end
