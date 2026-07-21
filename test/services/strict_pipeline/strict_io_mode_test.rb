# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

module StrictPipeline
  class StrictIoModeTest < ActiveSupport::TestCase
    setup do
      @previous_value =
        ENV.key?(StrictIoMode::ENV_KEY) ?
          ENV[StrictIoMode::ENV_KEY] :
          :missing
    end

    teardown do
      if @previous_value == :missing
        ENV.delete(StrictIoMode::ENV_KEY)
      else
        ENV[StrictIoMode::ENV_KEY] = @previous_value
      end
    end

    test "defaults to serialized" do
      ENV.delete(StrictIoMode::ENV_KEY)

      assert_equal StrictIoMode::SERIALIZED, StrictIoMode.current
      refute StrictIoMode.concurrent_ssd?
    end

    test "accepts concurrent ssd explicitly" do
      ENV[StrictIoMode::ENV_KEY] = StrictIoMode::CONCURRENT_SSD

      assert_equal StrictIoMode::CONCURRENT_SSD, StrictIoMode.current
      assert StrictIoMode.concurrent_ssd?
    end

    test "unknown value warns and falls back to serialized" do
      ENV[StrictIoMode::ENV_KEY] = "unknown"
      logger = Minitest::Mock.new

      logger.expect(
        :warn,
        nil,
        [
          "[strict_io_mode] unknown_value=\"unknown\" " \
          "fallback=serialized"
        ]
      )

      assert_equal StrictIoMode::SERIALIZED, StrictIoMode.current(logger: logger)
      logger.verify
    end
  end
end
