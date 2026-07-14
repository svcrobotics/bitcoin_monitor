# frozen_string_literal: true

require "test_helper"

module Layer1
  class HistoricalWorkConfigTest < ActiveSupport::TestCase
    test "uses conservative defaults" do
      with_env(
        "HISTORICAL_MAX_LAYER1_LAG_BLOCKS" => nil,
        "HISTORICAL_MAX_CLUSTER_LAG_BLOCKS" => nil
      ) do
        assert_equal(
          6,
          HistoricalWorkConfig
            .max_layer1_lag_blocks
        )

        assert_equal(
          12,
          HistoricalWorkConfig
            .max_cluster_lag_blocks
        )
      end
    end

    test "accepts configured budgets" do
      with_env(
        "HISTORICAL_MAX_LAYER1_LAG_BLOCKS" => "10",
        "HISTORICAL_MAX_CLUSTER_LAG_BLOCKS" => "5"
      ) do
        assert_equal(
          10,
          HistoricalWorkConfig
            .max_layer1_lag_blocks
        )

        assert_equal(
          5,
          HistoricalWorkConfig
            .max_cluster_lag_blocks
        )
      end
    end

    test "normalizes empty invalid and bounded values for both budgets" do
      cases = {
        "HISTORICAL_MAX_LAYER1_LAG_BLOCKS" => {
          reader: :max_layer1_lag_blocks,
          default: 6
        },
        "HISTORICAL_MAX_CLUSTER_LAG_BLOCKS" => {
          reader: :max_cluster_lag_blocks,
          default: 12
        }
      }

      cases.each do |name, contract|
        assert_budget(name, contract[:reader], "", contract[:default])
        assert_budget(name, contract[:reader], "invalid", contract[:default])
        assert_budget(name, contract[:reader], "12.5", contract[:default])
        assert_budget(name, contract[:reader], "-4", 0)
        assert_budget(name, contract[:reader], "0", 0)
        assert_budget(name, contract[:reader], "100", 100)
        assert_budget(name, contract[:reader], "101", 100)
      end
    end

    private

    def assert_budget(name, reader, value, expected)
      with_env(name => value) do
        assert_equal expected, HistoricalWorkConfig.public_send(reader)
      end
    end

    def with_env(values)
      previous =
        values.to_h do |name, _value|
          [name, ENV[name]]
        end

      values.each do |name, value|
        if value.nil?
          ENV.delete(name)
        else
          ENV[name] = value
        end
      end

      yield
    ensure
      previous.each do |name, value|
        if value.nil?
          ENV.delete(name)
        else
          ENV[name] = value
        end
      end
    end
  end
end
