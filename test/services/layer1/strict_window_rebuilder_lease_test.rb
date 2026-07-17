# frozen_string_literal: true

require "test_helper"

module Layer1
  class StrictWindowRebuilderLeaseTest < ActiveSupport::TestCase
    test "renews strict io lease before and after each block" do
      renew_calls = []

      rebuilder =
        StrictWindowRebuilder.new(
          from_height: 100,
          to_height: 101,
          strict_io_token: "layer1-token"
        )

      rebuilder.define_singleton_method(:process_height) do |height|
        {
          ok: true,
          height: height
        }
      end

      with_stubbed(
        StrictPipeline::StrictIoLease,
        :renew,
        lambda do |owner:, token:, **_kwargs|
          renew_calls << [owner, token]
          true
        end
      ) do
        result = rebuilder.call

        assert result[:ok]
        assert_equal 2, result[:processed]
      end

      assert_equal(
        [
          ["layer1", "layer1-token"],
          ["layer1", "layer1-token"],
          ["layer1", "layer1-token"],
          ["layer1", "layer1-token"]
        ],
        renew_calls
      )
    end

    private

    def with_stubbed(object, method_name, value = nil)
      original = object.method(method_name)
      replacement =
        if value.respond_to?(:call)
          value
        else
          ->(*_args, **_kwargs) { value }
        end

      object.define_singleton_method(method_name, &replacement)

      yield
    ensure
      object.define_singleton_method(method_name) do |*args, **kwargs, &block|
        original.call(*args, **kwargs, &block)
      end
    end
  end
end
