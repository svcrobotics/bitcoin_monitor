# frozen_string_literal: true

require "test_helper"

module Layer1
  class StrictTipSyncerTest < ActiveSupport::TestCase
    class FakeRedis
      def initialize
        @values = {}
      end

      def set(key, value, nx:, **_options)
        return false if nx && @values.key?(key)

        @values[key] = value
        true
      end

      def get(key)
        @values[key]
      end

      def del(key)
        @values.delete(key)
        1
      end

      def llen(_key)
        0
      end
    end

    test "large backlog starts at the height after the certified checkpoint" do
      rpc = Struct.new(:getblockcount).new(959_500)
      logger = ActiveSupport::Logger.new(nil)
      syncer =
        StrictTipSyncer.new(
          rpc: rpc,
          redis: FakeRedis.new,
          logger: logger,
          max_blocks: 1
        )
      observed_tips = [ 959_400, 959_401 ]
      rebuilds = []

      with_stubbed(
        syncer,
        :continuous_processed_tip,
        -> { observed_tips.shift }
      ) do
        with_stubbed(syncer, :detect_reorg, nil) do
          with_stubbed(
            StrictWindowRebuilder,
            :call,
            lambda do |**kwargs|
              rebuilds << kwargs
              {
                ok: true,
                processed: 1,
                failed: 0
              }
            end
          ) do
            result = syncer.call

            assert result[:ok]
            assert_equal 959_401, result[:from_height]
            assert_equal 959_401, result[:to_height]
          end
        end
      end

      assert_equal(
        [
          {
            from_height: 959_401,
            to_height: 959_401,
            strict_io_token: nil
          }
        ],
        rebuilds
      )
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
