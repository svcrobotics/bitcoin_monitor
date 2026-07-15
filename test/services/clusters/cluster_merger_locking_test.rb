# frozen_string_literal: true

require "test_helper"

module Clusters
  class ClusterMergerLockingTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    def setup
      @prefix = "cluster-locking-#{SecureRandom.hex(8)}"
    end

    def teardown
      Address.where("address LIKE ?", "#{@prefix}%").delete_all
      Cluster.where("address_count = 0").delete_all
    end

    test "concurrent merge is blocked by deterministic row locks" do
      first = Cluster.create!(composition_version: 1)
      second = Cluster.create!(composition_version: 1)
      first_address = Address.create!(address: "#{@prefix}-merge-a", cluster: first)
      second_address = Address.create!(address: "#{@prefix}-merge-b", cluster: second)
      ready = Queue.new
      release = Queue.new

      holder = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ApplicationRecord.transaction do
            Clusters::ClusterMerger.call(
              address_records: [first_address.reload, second_address.reload]
            )
            ready << true
            release.pop
          end
        end
      end
      ready.pop

      assert_raises(ActiveRecord::LockWaitTimeout, ActiveRecord::StatementInvalid) do
        with_short_lock_timeout do
          Clusters::ClusterMerger.call(
            address_records: [second_address, first_address.reload]
          )
        end
      end
    ensure
      release << true if release
      holder&.join
    end

    test "concurrent attach is blocked by target cluster and address locks" do
      cluster = Cluster.create!(composition_version: 1)
      existing = Address.create!(address: "#{@prefix}-attach-existing", cluster: cluster)
      unclustered = Address.create!(address: "#{@prefix}-attach-new")
      ready = Queue.new
      release = Queue.new

      holder = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ApplicationRecord.transaction do
            Clusters::ClusterMerger.call(
              address_records: [unclustered.reload, existing.reload]
            )
            ready << true
            release.pop
          end
        end
      end
      ready.pop

      assert_raises(ActiveRecord::LockWaitTimeout, ActiveRecord::StatementInvalid) do
        with_short_lock_timeout do
          Clusters::ClusterMerger.call(
            address_records: [existing.reload, unclustered]
          )
        end
      end
    ensure
      release << true if release
      holder&.join
    end

    private

    def with_short_lock_timeout
      connection = ActiveRecord::Base.connection
      connection.execute("SET lock_timeout = '100ms'")
      yield
    ensure
      connection&.execute("RESET lock_timeout")
    end
  end
end
