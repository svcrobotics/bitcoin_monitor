# frozen_string_literal: true

require "test_helper"

module StrictPipeline
  class StrictIoLeaseTest < ActiveSupport::TestCase
    test "reports the non-authoritative lease as explicitly unavailable" do
      observation = StrictIoLease.current

      assert_equal "unavailable", observation.status
      assert_equal false, observation.available?
      assert_equal "strict_io_lease_unavailable", observation.reason
      assert_nil observation.owner
      assert_nil observation.acquired_at
      assert_nil observation.expires_at
      assert JSON.generate(observation.to_h)
    end

    test "does not expose a false acquisition authority" do
      refute_respond_to StrictIoLease, :acquire
      refute_respond_to StrictIoLease, :renew
      refute_respond_to StrictIoLease, :release

      source = Rails.root.join(
        "app/services/strict_pipeline/strict_io_lease.rb"
      ).read

      refute_match(/Redis|Sidekiq|SET|EVAL/, source)
    end

    test "strict IO constraints fail closed while observation is unavailable" do
      snapshot = {
        strict_io: StrictIoLease.current.to_h
      }

      refute System::PipelineController.constraint_met?(
        :strict_io_idle,
        snapshot
      )
      refute System::PipelineController.constraint_met?(
        :strict_io_not_layer1,
        snapshot
      )
    end

    test "strict IO constraints require an explicitly available observation" do
      idle = {
        strict_io: {
          available: true,
          owner: nil
        }
      }
      layer1 = {
        strict_io: {
          available: true,
          owner: "layer1"
        }
      }

      assert System::PipelineController.constraint_met?(:strict_io_idle, idle)
      assert System::PipelineController.constraint_met?(:strict_io_not_layer1, idle)
      refute System::PipelineController.constraint_met?(:strict_io_idle, layer1)
      refute System::PipelineController.constraint_met?(:strict_io_not_layer1, layer1)
    end
  end
end
