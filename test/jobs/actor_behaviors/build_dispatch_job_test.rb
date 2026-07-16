# frozen_string_literal: true

require "test_helper"

module ActorBehaviors
  class BuildDispatchJobTest < ActiveSupport::TestCase
    test "uses the strict queue, gate, bounded dispatcher and one successor" do
      events = []
      decision = ->(role) { events << [:gate, role]; { allowed: true } }
      dispatch = ->(limit:) { events << [:dispatch, limit]; { ok: true, claimed: 1 } }
      scheduler = Object.new
      scheduler.define_singleton_method(:perform_later) do |limit:|
        events << [:schedule, limit]
      end

      with_singleton_method(System::PipelineController, :decision, decision) do
        with_singleton_method(BuildDispatcher, :call, dispatch) do
          with_singleton_method(BuildDispatcher, :work_available?, -> { true }) do
            with_singleton_method(BuildDispatchJob, :set, ->(wait:) {
              events << [:wait, wait]; scheduler
            }) do
              result = BuildDispatchJob.new.perform(limit: 500)
              assert_equal true, result[:ok]
            end
          end
        end
      end

      assert_equal "actor_behavior_strict", BuildDispatchJob.queue_name
      assert_equal [
        [:gate, :actor_behavior], [:dispatch, 100], [:wait, 5.seconds], [:schedule, 100]
      ], events
    end

    test "gate refusal and invalid decisions fail closed before claim" do
      with_singleton_method(System::PipelineController, :decision, ->(*) { { allowed: false } }) do
        with_singleton_method(BuildDispatcher, :call, ->(**) { flunk "must not claim" }) do
          result = BuildDispatchJob.new.perform
          assert_equal "skipped", result[:status]
        end
      end

      with_singleton_method(System::PipelineController, :decision, ->(*) { {} }) do
        assert_raises(RuntimeError) { BuildDispatchJob.new.perform }
      end
    end

    test "dispatcher errors propagate and no successor is created" do
      original = RuntimeError.new("dispatch failed")
      with_singleton_method(System::PipelineController, :decision, ->(*) { { allowed: true } }) do
        with_singleton_method(BuildDispatcher, :call, ->(**) { raise original }) do
          with_singleton_method(BuildDispatchJob, :set, ->(*) { flunk "must not schedule" }) do
            error = assert_raises(RuntimeError) { BuildDispatchJob.new.perform }
            assert_same original, error
          end
        end
      end
    end

    private

    def with_singleton_method(target, method_name, replacement)
      singleton = target.singleton_class
      original = :"#{method_name}_without_dispatch_job_test"
      singleton.alias_method(original, method_name)
      singleton.define_method(method_name, &replacement)
      yield
    ensure
      singleton.alias_method(method_name, original)
      singleton.remove_method(original)
    end
  end
end
