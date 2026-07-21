# frozen_string_literal: true

require "open3"

if ENV["TEST_REDIS_BOOT_PROBE"] == "1"
  require_relative "../test_helper"

  class TestRedisBootProbeTest < ActiveSupport::TestCase
    test "Redis clients are configured for the safe test database" do
      assert_equal "redis://127.0.0.1:6379/15", ENV.fetch("REDIS_URL")

      sidekiq_config =
        Sidekiq.default_configuration.instance_variable_get(:@redis_config)
      assert_equal ENV.fetch("REDIS_URL"), sidekiq_config.fetch(:url)

      redis_client = REDIS.instance_variable_get(:@client)
      assert_equal 15, redis_client.config.db
    end
  end
else
  require_relative "../test_helper"

  class TestRedisConfigurationTest < ActiveSupport::TestCase
    SAFE_URL = "redis://127.0.0.1:6379/15"
    TEST_FILE = "test/config/test_redis_configuration_test.rb"

    test "defaults to Redis DB 15" do
      assert_equal SAFE_URL, TestRedisConfiguration.resolve({})
    end

    test "accepts a valid non-zero TEST_REDIS_URL" do
      url = "rediss://user:secret@redis.test:6380/14"

      assert_equal(
        url,
        TestRedisConfiguration.resolve("TEST_REDIS_URL" => url)
      )
    end

    test "ignores an external REDIS_URL when TEST_REDIS_URL is absent" do
      assert_equal(
        SAFE_URL,
        TestRedisConfiguration.resolve(
          "REDIS_URL" => "redis://development.test:6379/0"
        )
      )
    end

    test "rejects Redis DB 0 without exposing the URL" do
      secret_url = "redis://user:very-secret@redis.test:6379/0"

      error =
        assert_raises(ArgumentError) do
          TestRedisConfiguration.validate!(secret_url)
        end

      assert_equal TestRedisConfiguration::DB_ZERO_ERROR, error.message
      refute_includes error.message, "very-secret"
      refute_includes error.message, "redis.test"
    end

    test "rejects an empty URL" do
      assert_invalid_url("")
    end

    test "rejects an invalid URI" do
      assert_invalid_url("redis://[invalid/15")
    end

    test "rejects an unsupported scheme" do
      assert_invalid_url("http://redis.test:6379/15")
    end

    test "rejects a missing database" do
      assert_invalid_url("redis://redis.test:6379")
    end

    test "rejects a negative database" do
      assert_invalid_url("redis://redis.test:6379/-1")
    end

    test "rejects ambiguous database paths" do
      assert_invalid_url("redis://redis.test:6379/15/extra")
      assert_invalid_url("redis://redis.test:6379/15/")
    end

    test "Sidekiq and the global Redis client use the safe URL without connecting" do
      sidekiq_config =
        Sidekiq.default_configuration.instance_variable_get(:@redis_config)
      assert_equal SAFE_URL, sidekiq_config.fetch(:url)

      redis_client = REDIS.instance_variable_get(:@client)
      assert_equal 15, redis_client.config.db
    end

    test "bin rails test without arguments boots with DB 15 before initializers" do
      stdout, stderr, status = boot_probe(default_test: TEST_FILE)

      assert status.success?, failure_message(stdout, stderr)
      assert_includes stdout, "1 runs, 3 assertions, 0 failures, 0 errors"
      refute_match(%r{redis://[^\s]*/0\b}, stdout + stderr)
    end

    test "targeted bin rails test boots with DB 15 before initializers" do
      stdout, stderr, status = boot_probe(TEST_FILE)

      assert status.success?, failure_message(stdout, stderr)
      assert_includes stdout, "1 runs, 3 assertions, 0 failures, 0 errors"
      refute_match(%r{redis://[^\s]*/0\b}, stdout + stderr)
    end

    test "DB 0 fails in a subprocess before Redis initializers" do
      stdout, stderr, status =
        Open3.capture3(
          boot_environment(
            "TEST_REDIS_URL" => "redis://user:secret@127.0.0.1:6379/0"
          ),
          "bin/rails",
          "test",
          TEST_FILE
        )

      refute status.success?
      assert_includes(
        stderr,
        "Unsafe Redis configuration: RAILS_ENV=test cannot use Redis DB 0"
      )
      refute_includes stdout + stderr, "secret"
      refute_includes stdout + stderr, "Sidekiq"
    end

    test "Action Cable and Rails cache remain isolated from Redis" do
      cable_config = Rails.application.config_for(:cable)

      assert_equal "test", cable_config.fetch(:adapter)
      assert_instance_of ActiveSupport::Cache::NullStore, Rails.cache
    end

    private

    def assert_invalid_url(url)
      error =
        assert_raises(ArgumentError) do
          TestRedisConfiguration.validate!(url)
        end

      assert_equal TestRedisConfiguration::INVALID_URL_ERROR, error.message
      refute_includes error.message, url unless url.empty?
    end

    def boot_probe(*arguments, default_test: nil)
      Open3.capture3(
        boot_environment("DEFAULT_TEST" => default_test),
        "bin/rails",
        "test",
        *arguments
      )
    end

    def boot_environment(overrides = {})
      {
        "RAILS_ENV" => "test",
        "TEST_REDIS_URL" => SAFE_URL,
        "REDIS_URL" => SAFE_URL,
        "PARALLEL_WORKERS" => "1",
        "TEST_REDIS_BOOT_PROBE" => "1"
      }.merge(overrides)
    end

    def failure_message(stdout, stderr)
      "boot probe failed\nstdout:\n#{stdout}\nstderr:\n#{stderr}"
    end
  end
end
