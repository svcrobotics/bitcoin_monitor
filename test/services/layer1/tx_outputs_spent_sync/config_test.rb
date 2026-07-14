# frozen_string_literal: true

require "test_helper"

module Layer1
  module TxOutputsSpentSync
    class ConfigTest < ActiveSupport::TestCase
      ENGINE_ENV_KEYS = %w[
        TX_OUTPUTS_SPENT_ASYNC
        TX_OUTPUTS_SPENT_ASYNC_BATCH_SIZE
        TX_OUTPUTS_SPENT_ASYNC_MAX_LAYER1_LAG
        TX_OUTPUTS_SPENT_ASYNC_RETRY_WAIT_SECONDS
        TX_OUTPUTS_SPENT_ASYNC_MAX_ATTEMPTS
        TX_OUTPUTS_SPENT_SYNC_STALE_AFTER_SECONDS
        TX_OUTPUTS_SPENT_ASYNC_PROCESSING_STALE_AFTER_SECONDS
      ].freeze

      setup do
        @previous_env = ENGINE_ENV_KEYS.to_h { |key| [key, ENV[key]] }
        ENGINE_ENV_KEYS.each { |key| ENV.delete(key) }
      end

      teardown do
        ENGINE_ENV_KEYS.each do |key|
          value = @previous_env.fetch(key)
          value.nil? ? ENV.delete(key) : ENV[key] = value
        end
      end

      test "uses deterministic engine defaults" do
        assert_equal false, Config.enabled?
        assert_equal 500, Config.batch_size
        assert_equal 0, Config.max_layer1_lag
        assert_equal 30, Config.retry_wait_seconds
        assert_equal 10, Config.max_attempts
        assert_equal 900, Config.processing_stale_after_seconds
      end

      test "reads and bounds engine environment values" do
        ENV["TX_OUTPUTS_SPENT_ASYNC"] = "yes"
        ENV["TX_OUTPUTS_SPENT_ASYNC_BATCH_SIZE"] = "0"
        ENV["TX_OUTPUTS_SPENT_ASYNC_MAX_LAYER1_LAG"] = "-2"
        ENV["TX_OUTPUTS_SPENT_ASYNC_RETRY_WAIT_SECONDS"] = "1"
        ENV["TX_OUTPUTS_SPENT_ASYNC_MAX_ATTEMPTS"] = "0"
        ENV["TX_OUTPUTS_SPENT_SYNC_STALE_AFTER_SECONDS"] = "30"

        assert_equal true, Config.enabled?
        assert_equal 1, Config.batch_size
        assert_equal 0, Config.max_layer1_lag
        assert_equal 5, Config.retry_wait_seconds
        assert_equal 1, Config.max_attempts
        assert_equal 60, Config.processing_stale_after_seconds
      end
    end
  end
end
