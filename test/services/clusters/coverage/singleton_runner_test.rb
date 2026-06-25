# frozen_string_literal: true

require "bech32"
require "minitest/mock"
require "test_helper"

module Clusters
  module Coverage
    class SingletonRunnerTest < ActiveSupport::TestCase
      SeparateConnectionBase =
        Class.new(ActiveRecord::Base) do
          self.abstract_class = true
        end

      test "processes several batches until an empty batch" do
        after_id =
          Address.maximum(:id).to_i

        addresses =
          3.times.map do |index|
            Address.create!(
              address: segwit_address(index + 1)
            )
          end

        result =
          Clusters::Coverage::SingletonRunner.call(
            batch_size: 2,
            max_batches: 5,
            after_id: after_id,
            lock: false
          )

        assert_equal true, result[:ok]
        assert_equal "empty_batch", result[:stopped_reason]
        assert_equal 2, result[:batches]
        assert_equal 3, result[:scanned]
        assert_equal 3, result[:valid_addresses]
        assert_equal 3, result[:updated]
        assert_equal 3, result[:singleton_clusters_created]
        assert_equal addresses.last.id, result[:last_address_id]
        assert_performance_metrics(result)
        assert_equal 3, addresses.map { |address| address.reload.cluster_id }.compact.uniq.size
      end

      test "returns duration metrics measured with the monotonic clock" do
        current = 99.75
        clock_ids = []

        clock =
          lambda do |clock_id|
            clock_ids << clock_id
            current += 0.25
          end

        builder =
          lambda do |batch_size:, after_id:|
            {
              ok: true,
              scanned: 100,
              valid_addresses: 100,
              invalid_addresses: 0,
              updated: 100,
              singleton_clusters_created: 100,
              ignored_already_clustered: 0,
              last_address_id: 100
            }
          end

        Process.stub(:clock_gettime, clock) do
          Clusters::Coverage::SingletonBuilder.stub(:call, builder) do
            result =
              Clusters::Coverage::SingletonRunner.call(
                batch_size: 100,
                max_batches: 1,
                lock: false
              )

            assert_equal true, result[:ok]
            assert_equal 250, result[:duration_ms]
            assert_equal 0.25, result[:duration_seconds]
            assert_equal 400.0, result[:addresses_per_second]
          end
        end

        assert_operator clock_ids.size, :>=, 2
        assert clock_ids.all? { |clock_id| clock_id == Process::CLOCK_MONOTONIC }
      end

      test "passes the configured batch size to the builder" do
        seen_batch_sizes = []

        builder =
          lambda do |batch_size:, after_id:|
            seen_batch_sizes << batch_size

            {
              ok: true,
              scanned: after_id ? 0 : 1,
              valid_addresses: after_id ? 0 : 1,
              invalid_addresses: 0,
              updated: after_id ? 0 : 1,
              singleton_clusters_created: after_id ? 0 : 1,
              ignored_already_clustered: 0,
              last_address_id: after_id ? nil : 10
            }
          end

        Clusters::Coverage::SingletonBuilder.stub(:call, builder) do
          result =
            Clusters::Coverage::SingletonRunner.call(
              batch_size: 7,
              max_batches: 2,
              lock: false
            )

          assert_equal true, result[:ok]
        end

        assert_equal [7, 7], seen_batch_sizes
      end

      test "stops at max_batches" do
        calls = 0

        builder =
          lambda do |batch_size:, after_id:|
            calls += 1

            {
              ok: true,
              scanned: 1,
              valid_addresses: 1,
              invalid_addresses: 0,
              updated: 1,
              singleton_clusters_created: 1,
              ignored_already_clustered: 0,
              last_address_id: after_id.to_i + 1
            }
          end

        Clusters::Coverage::SingletonBuilder.stub(:call, builder) do
          result =
            Clusters::Coverage::SingletonRunner.call(
              batch_size: 1,
              max_batches: 2,
              after_id: 100,
              lock: false
            )

          assert_equal true, result[:ok]
          assert_equal "max_batches", result[:stopped_reason]
          assert_equal 2, result[:batches]
          assert_equal 2, result[:scanned]
          assert_equal 102, result[:last_address_id]
        end

        assert_equal 2, calls
      end

      test "is idempotent on second run" do
        after_id =
          Address.maximum(:id).to_i

        addresses =
          2.times.map do |index|
            Address.create!(
              address: segwit_address(index + 20)
            )
          end

        first_result =
          Clusters::Coverage::SingletonRunner.call(
            batch_size: 1,
            max_batches: 5,
            after_id: after_id,
            lock: false
          )

        cluster_ids =
          addresses.map { |address| address.reload.cluster_id }

        assert_equal 2, first_result[:updated]
        assert_equal 2, cluster_ids.compact.uniq.size

        assert_no_difference -> { Cluster.count } do
          second_result =
            Clusters::Coverage::SingletonRunner.call(
              batch_size: 1,
              max_batches: 5,
              after_id: after_id,
              lock: false
            )

          assert_equal true, second_result[:ok]
          assert_equal "empty_batch", second_result[:stopped_reason]
          assert_equal 0, second_result[:batches]
          assert_equal 0, second_result[:updated]
        end

        assert_equal cluster_ids, addresses.map { |address| address.reload.cluster_id }
      end

      test "returns already running when the advisory lock is held" do
        with_separate_connection do |connection|
          assert_equal(
            true,
            advisory_lock(connection)
          )

          result =
            Clusters::Coverage::SingletonRunner.call(
              batch_size: 1,
              max_batches: 1,
              lock: true
            )

          assert_equal false, result[:ok]
          assert_equal false, result[:locked]
          assert_equal "already_running", result[:stopped_reason]
          assert_equal 0, result[:batches]
          assert_performance_metrics(result)
        ensure
          advisory_unlock(connection)
        end
      end

      test "releases the advisory lock after success" do
        result =
          Clusters::Coverage::SingletonRunner.call(
            batch_size: 1,
            max_batches: 1,
            after_id: Address.maximum(:id).to_i,
            lock: true
          )

        assert_equal true, result[:ok]
        assert lock_available_from_separate_connection?
      end

      test "releases the advisory lock after error" do
        builder =
          lambda do |batch_size:, after_id:|
            raise "coverage failure"
          end

        Clusters::Coverage::SingletonBuilder.stub(:call, builder) do
          result =
            Clusters::Coverage::SingletonRunner.call(
              batch_size: 1,
              max_batches: 1,
              lock: true
            )

          assert_equal false, result[:ok]
          assert_equal "error", result[:stopped_reason]
          assert_equal "RuntimeError", result[:error_class]
          assert_performance_metrics(result)
        end

        assert lock_available_from_separate_connection?
      end

      test "returns partial metrics on error" do
        calls = 0

        builder =
          lambda do |batch_size:, after_id:|
            calls += 1
            raise "second batch failed" if calls == 2

            {
              ok: true,
              scanned: 3,
              valid_addresses: 2,
              invalid_addresses: 1,
              updated: 2,
              singleton_clusters_created: 2,
              ignored_already_clustered: 0,
              last_address_id: 42
            }
          end

        Clusters::Coverage::SingletonBuilder.stub(:call, builder) do
          result =
            Clusters::Coverage::SingletonRunner.call(
              batch_size: 3,
              max_batches: 5,
              lock: false
            )

          assert_equal false, result[:ok]
          assert_equal "error", result[:stopped_reason]
          assert_equal 1, result[:batches]
          assert_equal 3, result[:scanned]
          assert_equal 2, result[:valid_addresses]
          assert_equal 1, result[:invalid_addresses]
          assert_equal 2, result[:updated]
          assert_equal 2, result[:singleton_clusters_created]
          assert_equal 42, result[:last_address_id]
          assert_equal "RuntimeError", result[:error_class]
          assert_equal "second batch failed", result[:error_message]
          assert_performance_metrics(result)
        end
      end

      test "does not create address links" do
        after_id =
          Address.maximum(:id).to_i

        Address.create!(
          address: segwit_address(50)
        )

        assert_no_difference -> { AddressLink.count } do
          Clusters::Coverage::SingletonRunner.call(
            batch_size: 1,
            max_batches: 2,
            after_id: after_id,
            lock: false
          )
        end
      end

      test "does not reference tx outputs" do
        source =
          Rails.root.join(
            "app/services/clusters/coverage/singleton_runner.rb"
          ).read

        refute_match(/TxOutput|tx_outputs/, source)
      end

      test "does not modify an address that already has a cluster" do
        after_id =
          Address.maximum(:id).to_i

        cluster =
          Cluster.create!(
            composition_version: 7
          )

        address =
          Address.create!(
            address: segwit_address(70),
            cluster: cluster
          )

        updated_at =
          address.updated_at

        assert_no_difference -> { Cluster.count } do
          result =
            Clusters::Coverage::SingletonRunner.call(
              batch_size: 1,
              max_batches: 2,
              after_id: after_id,
              lock: false
            )

          assert_equal true, result[:ok]
          assert_equal 0, result[:scanned]
          assert_equal 0, result[:updated]
        end

        address.reload

        assert_equal cluster.id, address.cluster_id
        assert_equal updated_at.to_i, address.updated_at.to_i
      end

      private

      def segwit_address(seed)
        program =
          Array.new(20, seed)

        data =
          [0] +
          Bech32.convert_bits(
            program,
            8,
            5,
            true
          )

        Bech32.encode(
          "bc",
          data,
          Bech32::Encoding::BECH32
        )
      end

      def assert_performance_metrics(result)
        assert_kind_of Integer, result[:duration_ms]
        assert_operator result[:duration_ms], :>=, 0

        assert_kind_of Float, result[:duration_seconds]
        assert_operator result[:duration_seconds], :>=, 0.0

        assert_kind_of Float, result[:addresses_per_second]
        assert_operator result[:addresses_per_second], :>=, 0.0
      end

      def with_separate_connection
        SeparateConnectionBase.establish_connection(
          ActiveRecord::Base
            .connection_db_config
            .configuration_hash
        )

        yield SeparateConnectionBase.connection
      ensure
        SeparateConnectionBase.connection_pool.disconnect!
      end

      def lock_available_from_separate_connection?
        with_separate_connection do |connection|
          locked =
            advisory_lock(connection)

          advisory_unlock(connection) if locked

          locked
        end
      end

      def advisory_lock(connection)
        value =
          connection.select_value(
            "SELECT pg_try_advisory_lock(" \
            "#{Clusters::Coverage::SingletonRunner::ADVISORY_LOCK_KEY})"
          )

        value == true || value == "t"
      end

      def advisory_unlock(connection)
        connection.select_value(
          "SELECT pg_advisory_unlock(" \
          "#{Clusters::Coverage::SingletonRunner::ADVISORY_LOCK_KEY})"
        )
      end
    end
  end
end
