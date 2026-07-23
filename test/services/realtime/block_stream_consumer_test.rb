# frozen_string_literal: true

require "test_helper"

module Realtime
  class BlockStreamConsumerTest < ActiveSupport::TestCase
    test "new block wakes the deduplicated strict scheduler" do
      requests = []
      consumer = BlockStreamConsumer.allocate

      with_stubbed(
        StrictPipeline::SchedulerWakeup,
        :request!,
        lambda do |**kwargs|
          requests << kwargs
          { enqueued: true }
        end
      ) do
        with_stubbed(
          consumer,
          :enqueue_once,
          ->(_queue, _klass, &_block) { }
        ) do
          consumer.send(
            :process_event,
            "171-0",
            {
              "type" => "new_block",
              "height" => "959301",
              "blockhash" => "000000000000000000abc"
            }
          )
        end
      end

      assert_equal 1, requests.size
      assert_equal "bitcoin_block_event", requests.first[:reason]
    end

    test "non block event does not wake the strict scheduler" do
      requests = []
      consumer = BlockStreamConsumer.allocate

      with_stubbed(
        StrictPipeline::SchedulerWakeup,
        :request!,
        ->(**kwargs) { requests << kwargs }
      ) do
        consumer.send(
          :process_event,
          "172-0",
          {
            "type" => "heartbeat"
          }
        )
      end

      assert_empty requests
    end

    private

    def with_stubbed(object, method_name, value)
      original =
        object.method(method_name)

      replacement =
        value.respond_to?(:call) ? value : ->(*_args, **_kwargs) { value }

      object.define_singleton_method(method_name, &replacement)

      yield
    ensure
      object.define_singleton_method(method_name) do |*args, **kwargs, &block|
        original.call(*args, **kwargs, &block)
      end
    end
  end
end
