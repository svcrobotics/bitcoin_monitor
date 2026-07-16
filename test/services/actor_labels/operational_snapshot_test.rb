# frozen_string_literal: true
require "test_helper"
require "minitest/mock"
module ActorLabels
  class OperationalSnapshotTest < ActiveSupport::TestCase
    test "reports canonical rules and durable backlog without Redis" do
      control = { sidekiq_available: true, queue_size: 0, scheduled_size: 0,
        worker_busy: false }
      ControlSnapshot.stub(:call, control) do
        result = OperationalSnapshot.call
        assert_equal CertifiedRuleSet::RULE_VERSION, result[:rule_version]
        assert_equal %w[whale_like whale_candidate], result[:active_rules]
        assert_equal %w[accumulator_like distributor_like etf_candidate], result[:deferred_rules]
        assert JSON.generate(result)
      end
    end
  end
end
