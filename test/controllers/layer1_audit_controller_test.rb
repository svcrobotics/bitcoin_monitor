# frozen_string_literal: true

require "test_helper"

class Layer1AuditControllerTest < ActionDispatch::IntegrationTest
  setup do
    BlockBufferModel.delete_all
    Layer1AuditRun.delete_all

    (100..115).each do |height|
      BlockBufferModel.create!(
        height: height,
        block_hash: "processed-#{height}",
        status: "processed"
      )
    end

    BlockBufferModel.create!(
      height: 999,
      block_hash: "pending-999",
      status: "pending"
    )
  end

  test "enqueues exactly the next ten processed heights and returns the HEAD Turbo Stream" do
    calls = []
    result_builder = method(:enqueue_result)

    with_block_job_enqueue(->(height:) { calls << height; result_builder.call(height) }) do
      with_synchronous_audit_forbidden do
        post system_layer1_audit_run_path, as: :turbo_stream
      end
    end

    assert_response :success
    assert_equal Mime[:turbo_stream].to_s, response.media_type
    assert_includes response.body, 'turbo-stream action="replace" target="layer1_audit_panel"'
    assert_equal (101..110).to_a.reverse, calls
    assert_equal calls.uniq, calls
    refute_includes calls, 999
  end

  test "already enqueued is a normal idempotent result across requests" do
    acquired = {}
    created = []
    calls = []
    result_builder = method(:enqueue_result)
    enqueue =
      lambda do |height:|
        calls << height
        if acquired[height]
          { ok: true, status: "already_enqueued", height: height, enqueued: false }
        else
          acquired[height] = true
          created << height
          result_builder.call(height)
        end
      end

    with_block_job_enqueue(enqueue) do
      2.times do
        post system_layer1_audit_run_path, as: :turbo_stream
        assert_response :success
      end
    end

    expected = (101..110).to_a.reverse
    assert_equal expected + expected, calls
    assert_equal expected, created
  end

  test "enqueue error propagates and remaining heights are not claimed" do
    calls = []
    failure = Class.new(StandardError).new("enqueue failed")
    result_builder = method(:enqueue_result)
    enqueue =
      lambda do |height:|
        calls << height
        raise failure if calls.size == 3

        result_builder.call(height)
      end

    raised = assert_raises(failure.class) do
      with_block_job_enqueue(enqueue) do
        post system_layer1_audit_run_path, as: :turbo_stream
      end
    end

    assert_same failure, raised
    assert_equal [110, 109, 108], calls
  end

  test "controller uses only the deduplicated API and keeps strict rebuild synchronous" do
    controller = File.read(Rails.root.join("app/controllers/layer1_audit_controller.rb"))
    strict_rebuilder = File.read(Rails.root.join("app/services/layer1/strict_window_rebuilder.rb"))

    assert_includes controller, "Layer1::Audit::BlockJob.enqueue(height: height)"
    refute_match(/Layer1::AuditBlock\.call/, controller)
    refute_match(/BlockJob\.perform_async/, controller)
    assert_match(/Layer1::AuditBlock\.call\(height: height\)/, strict_rebuilder)
  end

  private

  def enqueue_result(height)
    {
      ok: true,
      status: "enqueued",
      height: height,
      enqueued: true,
      jid: "jid-#{height}"
    }
  end

  def with_block_job_enqueue(replacement)
    with_stubbed(Layer1::Audit::BlockJob, :enqueue, replacement) { yield }
  end

  def with_synchronous_audit_forbidden
    with_stubbed(
      Layer1::AuditBlock,
      :call,
      ->(**) { flunk("controller must not run Layer1::AuditBlock synchronously") }
    ) { yield }
  end

  def with_stubbed(object, method_name, replacement)
    original = object.method(method_name)
    object.define_singleton_method(method_name, &replacement)
    yield
  ensure
    object.define_singleton_method(method_name) do |*args, **kwargs, &block|
      original.call(*args, **kwargs, &block)
    end
  end
end
