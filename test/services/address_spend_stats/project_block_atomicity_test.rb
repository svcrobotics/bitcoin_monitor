# frozen_string_literal: true

require "test_helper"

module AddressSpendStats
  class ProjectBlockAtomicityTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    class SimulatedCrash < StandardError; end

    def setup
      @height = 1_600_000 + SecureRandom.random_number(10_000)
      @address = "bc1qaddressspendatomic#{SecureRandom.hex(12)}"
      cleanup!

      ClusterProcessedBlock.create!(
        height: @height,
        block_hash: "address-spend-atomic-#{@height}",
        status: "processed",
        scan_result: {},
        cleanup_result: {},
        audit_result: {},
        stage_timings: {},
        processed_at: Time.current
      )

      ClusterInput.create!(
        block_height: @height - 1,
        txid: "source-#{@height}",
        vout: 0,
        address: @address,
        amount_btc: BigDecimal("0.25"),
        spent: true,
        spent_txid: "spend-#{@height}",
        spent_block_height: @height
      )
    end

    def teardown
      cleanup!
    end

    test "statistics and completed checkpoint become visible in one commit" do
      reached_after_projection = Queue.new
      release_projection = Queue.new
      service = ProjectBlock.new(height: @height)
      original_projection = service.method(:project_rows!)

      service.define_singleton_method(:project_rows!) do
        metrics = original_projection.call
        reached_after_projection << true
        release_projection.pop
        metrics
      end

      worker = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection { service.call }
      end

      reached_after_projection.pop

      ApplicationRecord.uncached do
        assert_not AddressSpendStat.exists?(address: @address)
        assert_not AddressSpendProjectionBlock.exists?(height: @height)
      end

      release_projection << true
      result = worker.value

      ApplicationRecord.uncached do
        assert AddressSpendStat.exists?(address: @address)
        assert_equal "completed",
          AddressSpendProjectionBlock.find_by!(height: @height).status
      end
      assert_equal "completed", result[:status]
      assert JSON.generate(result)
    ensure
      release_projection << true if release_projection&.empty?
      worker&.join
    end

    test "an exception after statistics mutation rolls back statistics and processing checkpoint" do
      service = ProjectBlock.new(height: @height)
      original_projection = service.method(:project_rows!)

      service.define_singleton_method(:project_rows!) do
        original_projection.call
        raise SimulatedCrash, "interrupted after projection"
      end

      error = assert_raises(SimulatedCrash) { service.call }

      assert_equal "interrupted after projection", error.message
      assert_not AddressSpendStat.exists?(address: @address)

      checkpoint = AddressSpendProjectionBlock.find_by!(height: @height)
      assert_equal "failed", checkpoint.status
      assert_equal 1, checkpoint.attempts
      assert_nil checkpoint.completed_at
    end

    test "projection writes only its statistics and checkpoint tables" do
      statements = capture_sql { ProjectBlock.call(height: @height) }
      mutations = statements.select do |sql|
        sql.match?(/\b(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM)\b/i)
      end
      targets = mutations.flat_map do |sql|
        sql.scan(
          /\b(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+"?([a-z_]+)"?/i
        ).flatten
      end

      assert_includes targets, "address_spend_stats"
      assert_includes targets, "address_spend_projection_blocks"

      forbidden_tables = %w[
        cluster_inputs
        cluster_processed_blocks
        addresses
        clusters
        address_links
        actor_profiles
      ]

      forbidden_tables.each do |table|
        assert_not_includes targets, table
      end
    end

    private

    def capture_sql
      statements = []
      subscriber = lambda do |_name, _start, _finish, _id, payload|
        sql = payload[:sql].to_s
        statements << sql unless payload[:name] == "SCHEMA"
      end

      ActiveSupport::Notifications.subscribed(
        subscriber,
        "sql.active_record"
      ) { yield }

      statements
    end

    def cleanup!
      AddressSpendProjectionBlock.where(height: @height).delete_all if @height
      AddressSpendStat.where(address: @address).delete_all if @address
      ClusterInput.where(spent_block_height: @height).delete_all if @height
      ClusterProcessedBlock.where(height: @height).delete_all if @height
    end
  end
end
