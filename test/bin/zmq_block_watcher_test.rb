# frozen_string_literal: true

require "test_helper"
require "stringio"

load Rails.root.join("bin/zmq_block_watcher")

class ZmqBlockWatcherTest < ActiveSupport::TestCase
  test "logs a broadcast failure and accepts the next event" do
    calls = 0
    logger_output = StringIO.new
    logger = ActiveSupport::Logger.new(logger_output)
    missing_template = ActionView::MissingTemplate.new(
      [],
      "system/realtime/latest_block",
      [],
      true,
      {}
    )

    broadcaster = lambda do |**|
      calls += 1
      raise missing_template if calls == 1
    end

    with_stubbed(Realtime::BlockEventBroadcaster, :call, broadcaster) do
      with_stubbed(Rails, :logger, logger) do
        first_result = ZmqBlockWatcher.broadcast_block_event(
          height: 956_321,
          blockhash: "first_hash",
          created_at: Time.current
        )

        ZmqBlockWatcher.broadcast_block_event(
          height: 956_322,
          blockhash: "second_hash",
          created_at: Time.current
        )

        assert_equal false, first_result
      end
    end

    assert_equal 2, calls
    assert_includes logger_output.string, "turbo_broadcast_failed"
    assert_includes logger_output.string, "ActionView::MissingTemplate"
    assert_includes logger_output.string, "Missing partial"
  end

  private

  def with_stubbed(object, method_name, value)
    original = object.method(method_name)

    object.define_singleton_method(method_name) do |*args, **kwargs|
      value.respond_to?(:call) ? value.call(*args, **kwargs) : value
    end

    yield
  ensure
    object.define_singleton_method(method_name) do |*args, **kwargs, &block|
      original.call(*args, **kwargs, &block)
    end
  end
end
