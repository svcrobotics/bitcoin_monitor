# frozen_string_literal: true

require "test_helper"

module Layer1
  module TxOutputsSpentSync
    class OperationalSnapshotTest < ActiveSupport::TestCase
      test "reports historical projection state from sync records" do
        Layer1TxOutputSync.create!(
          height: 956_248,
          block_hash: "1" * 64,
          status: "synced"
        )
        Layer1TxOutputSync.create!(
          height: 956_249,
          block_hash: "2" * 64,
          status: "pending"
        )
        Layer1TxOutputSync.create!(
          height: 956_250,
          block_hash: "3" * 64,
          status: "failed",
          attempts: 1
        )

        with_stubbed(Config, :enabled?, true) do
          snapshot =
            Layer1::TxOutputsSpentSync::OperationalSnapshot.call(
              processed_height: 956_250
            )

          assert_equal "failed", snapshot[:status]
          assert snapshot[:enabled]
          assert_equal 1, snapshot[:pending_count]
          assert_equal 0, snapshot[:processing_count]
          assert_equal 1, snapshot[:failed_count]
          assert_equal 956_249, snapshot[:oldest_pending_height]
          assert_equal 956_248, snapshot[:last_synced_height]
          assert_equal 2, snapshot[:projection_lag_blocks]
        end
      end

      test "returns unavailable when projection state cannot be read" do
        with_stubbed(
          ActiveRecord::Base.connection,
          :data_source_exists?,
          ->(*) { raise "schema unavailable" }
        ) do
          snapshot =
            Layer1::TxOutputsSpentSync::OperationalSnapshot.call(
              processed_height: 956_250
            )

          assert_equal "unavailable", snapshot[:status]
          assert_match(/schema unavailable/, snapshot[:error])
        end
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
end
