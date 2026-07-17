# frozen_string_literal: true

require "test_helper"

module Clusters
  class StrictWindowRebuilderPreemptionTest < ActiveSupport::TestCase
    test "yields to layer1 before starting the next block" do
      decisions = [
        { allowed: true },
        {
          allowed: false,
          reason: :layer1_realtime_priority,
          failed_constraints: [:layer1_not_processing]
        }
      ]

      processed = []

      rebuilder =
        Clusters::StrictWindowRebuilder.new(
          from_height: 100,
          to_height: 101,
          yield_guard: ->(_height) { decisions.shift || decisions.last }
        )

      rebuilder.define_singleton_method(:process_block) do |height|
        processed << height

        {
          ok: true,
          height: height
        }
      end

      result = rebuilder.call

      assert result[:ok]
      assert_equal "yielded_to_layer1", result[:status]
      assert_equal [100], processed
      assert_equal 1, result[:processed]
      assert_equal 101, result.dig(:yielded, :next_height)
      assert_equal :layer1_realtime_priority, result.dig(:yielded, :decision, :reason)
    end

    test "renews cooperative lease guard before and after each block" do
      guard_calls = []
      processed = []

      rebuilder =
        Clusters::StrictWindowRebuilder.new(
          from_height: 100,
          to_height: 101,
          yield_guard:
            lambda do |height|
              guard_calls << height
              { allowed: true }
            end
        )

      rebuilder.define_singleton_method(:process_block) do |height|
        processed << height

        {
          ok: true,
          height: height
        }
      end

      result = rebuilder.call

      assert result[:ok]
      assert_equal "processed", result[:status]
      assert_equal [100, 101], processed
      assert_equal [100, 100, 101, 101], guard_calls
    end
  end
end
