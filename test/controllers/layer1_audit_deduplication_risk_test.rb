# frozen_string_literal: true

require "test_helper"

class Layer1AuditDeduplicationRiskControllerTest < ActionDispatch::IntegrationTest
  setup do
    Layer1AuditRun.delete_all
  end

  test "show calls the operational snapshot once and transmits its risk" do
    calls = 0
    snapshot = {
      deduplication_expiry_risk: {
        status: "warning",
        queue_latency_seconds: 1_875,
        marker_ttl_seconds: 3_600,
        queue_latency_to_ttl_ratio: 0.520_833
      }
    }

    with_operational_snapshot(-> { calls += 1; snapshot }) do
      get system_layer1_audit_path
    end

    assert_response :success
    assert_equal 1, calls
    assert_includes response.body, "Expiration de la déduplication à surveiller"
    assert_includes response.body, "1 875 s"
    assert_includes response.body, "52,1%"
  end

  test "candidate preserves the deduplicated run action" do
    source = Rails.root.join("app/controllers/layer1_audit_controller.rb").read
    run_source = source[/^  def run\n.*?^  end\n/m]

    assert_not_nil run_source
    assert_includes run_source, "Layer1::Audit::BlockJob.enqueue(height: height)"
    refute_match(/perform_async/, run_source)
    refute_match(/Layer1::AuditBlock\.call/, run_source)
  end

  private

  def with_operational_snapshot(replacement)
    original = Layer1::Audit::OperationalSnapshot.method(:call)
    Layer1::Audit::OperationalSnapshot.define_singleton_method(:call, &replacement)
    yield
  ensure
    Layer1::Audit::OperationalSnapshot.define_singleton_method(:call) do |*args, **kwargs, &block|
      original.call(*args, **kwargs, &block)
    end
  end
end
