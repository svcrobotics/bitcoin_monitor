# frozen_string_literal: true

require "test_helper"

class StrictPipeline::PostgresWriteBarrierTest < ActiveSupport::TestCase
  setup do
    @previous_mode = ENV[StrictPipeline::StrictIoMode::ENV_KEY]
    ENV[StrictPipeline::StrictIoMode::ENV_KEY] =
      StrictPipeline::StrictIoMode::SERIALIZED
  end

  teardown do
    if @previous_mode.nil?
      ENV.delete(StrictPipeline::StrictIoMode::ENV_KEY)
    else
      ENV[StrictPipeline::StrictIoMode::ENV_KEY] = @previous_mode
    end
  end

  class FakeConnection
    attr_reader :queries, :disconnected

    def initialize(results)
      @results = results.dup
      @queries = []
      @disconnected = false
    end

    def select_value(sql)
      @queries << sql

      raise "missing fake PostgreSQL result" if @results.empty?

      result = @results.shift
      raise result if result.is_a?(Exception)

      result
    end

    def disconnect!
      @disconnected = true
    end
  end

  class FakePool
    attr_reader :connection

    def initialize(connection)
      @connection = connection
    end

    def with_connection
      yield connection
    end
  end

  test "returns the block result and releases the same session lock" do
    connection = FakeConnection.new([true, true])
    pool = FakePool.new(connection)

    result =
      StrictPipeline::PostgresWriteBarrier.with_lock(
        owner: "layer1",
        connection_pool: pool
      ) do
        :completed
      end

    assert_equal :completed, result
    assert_equal 2, connection.queries.size
    assert_includes connection.queries.first, "pg_try_advisory_lock"
    assert_includes connection.queries.last, "pg_advisory_unlock"
    assert_not connection.disconnected
  end

  test "fails immediately when another strict writer owns the lock" do
    connection = FakeConnection.new([false])
    pool = FakePool.new(connection)

    assert_raises(
      StrictPipeline::PostgresWriteBarrier::LockUnavailable
    ) do
      StrictPipeline::PostgresWriteBarrier.with_lock(
        owner: "cluster",
        connection_pool: pool
      ) do
        flunk "protected work must not execute"
      end
    end

    assert_equal 1, connection.queries.size
    assert_includes connection.queries.first, "pg_try_advisory_lock"
  end

  test "releases the advisory lock when protected work raises" do
    connection = FakeConnection.new([true, true])
    pool = FakePool.new(connection)

    error =
      assert_raises(RuntimeError) do
        StrictPipeline::PostgresWriteBarrier.with_lock(
          owner: "layer1",
          connection_pool: pool
        ) do
          raise "simulated failure"
        end
      end

    assert_equal "simulated failure", error.message
    assert_equal 2, connection.queries.size
    assert_includes connection.queries.last, "pg_advisory_unlock"
  end

  test "disconnects the PostgreSQL session when unlock is refused" do
    connection = FakeConnection.new([true, false])
    pool = FakePool.new(connection)

    assert_raises(
      StrictPipeline::PostgresWriteBarrier::UnlockFailed
    ) do
      StrictPipeline::PostgresWriteBarrier.with_lock(
        owner: "cluster",
        connection_pool: pool
      ) do
        :completed
      end
    end

    assert connection.disconnected
  end

  test "rejects an unknown owner" do
    connection = FakeConnection.new([])
    pool = FakePool.new(connection)

    assert_raises(ArgumentError) do
      StrictPipeline::PostgresWriteBarrier.with_lock(
        owner: "actor_profile",
        connection_pool: pool
      ) do
        :completed
      end
    end
  end

  test "serialized keeps the same advisory resource for layer1 and cluster" do
    layer1 = FakeConnection.new([true, true])
    cluster = FakeConnection.new([true, true])

    StrictPipeline::PostgresWriteBarrier.with_lock(
      owner: "layer1",
      connection_pool: FakePool.new(layer1)
    ) { true }

    StrictPipeline::PostgresWriteBarrier.with_lock(
      owner: "cluster",
      connection_pool: FakePool.new(cluster)
    ) { true }

    assert_equal lock_arguments(layer1.queries.first), lock_arguments(cluster.queries.first)
  end

  test "concurrent ssd gives layer1 and cluster distinct advisory resources" do
    ENV[StrictPipeline::StrictIoMode::ENV_KEY] =
      StrictPipeline::StrictIoMode::CONCURRENT_SSD

    layer1 = FakeConnection.new([true, true])
    cluster = FakeConnection.new([true, true])

    StrictPipeline::PostgresWriteBarrier.with_lock(
      owner: "layer1",
      connection_pool: FakePool.new(layer1)
    ) { true }

    StrictPipeline::PostgresWriteBarrier.with_lock(
      owner: "cluster",
      connection_pool: FakePool.new(cluster)
    ) { true }

    assert_equal [StrictPipeline::PostgresWriteBarrier::LOCK_NAMESPACE, 1],
      lock_arguments(layer1.queries.first)
    assert_equal [StrictPipeline::PostgresWriteBarrier::LOCK_NAMESPACE, 2],
      lock_arguments(cluster.queries.first)
  end

  private

  def lock_arguments(sql)
    sql.scan(/-?\d+/).map(&:to_i).last(2)
  end
end
