# frozen_string_literal: true

require "test_helper"

module System
  class AnomalyWatchdogTest < ActiveSupport::TestCase
    test "does not broadcast without notifyable transition" do
      with_stubbed(System::AnomalySnapshot, :call, { anomalies: [] }) do
        with_stubbed(System::AnomalyStateTracker, :call, { notifyable_events: [] }) do
          with_stubbed(System::AnomalyBroadcaster, :call, ->(*) { raise "no broadcast" }) do
            result =
              System::AnomalyWatchdog.call

            refute result[:notified]
          end
        end
      end
    end

    test "broadcasts a formatted notification for a new anomaly" do
      event =
        {
          transition: "new",
          code: "actor_profile_backlog_idle",
          module: "actor_profile",
          severity: "warning",
          title: "ActorProfile a du travail sans traitement actif",
          facts: {
            pending_work: 12
          },
          fingerprint: "actor_profile:backlog_idle",
          notify: true
        }

      broadcasted = []

      with_stubbed(System::AnomalySnapshot, :call, { anomalies: [event] }) do
        with_stubbed(System::AnomalyStateTracker, :call, { notifyable_events: [event] }) do
          with_stubbed(Ollama::AdminAlertFormatter, :call, "ActorProfile ne progresse plus.") do
            with_stubbed(System::AnomalyBroadcaster, :call, ->(notification:) {
              broadcasted << notification
            }) do
              result =
                System::AnomalyWatchdog.call

              assert result[:notified]
            end
          end
        end
      end

      assert_equal 1, broadcasted.size
      assert_equal "ActorProfile ne progresse plus.", broadcasted.first[:message]
    end

    test "layer1 stalled anomaly requests idempotent scheduler wakeup" do
      anomaly =
        {
          code: "layer1_stalled",
          module: "layer1",
          severity: "critical",
          title: "Layer1 est en rattrapage sans travail strict",
          fingerprint: "layer1:stalled"
        }

      requests = []

      with_stubbed(System::AnomalySnapshot, :call, { anomalies: [anomaly] }) do
        with_stubbed(System::AnomalyStateTracker, :call, { notifyable_events: [] }) do
          with_stubbed(
            StrictPipeline::SchedulerWakeup,
            :request!,
            lambda do |**kwargs|
              requests << kwargs
              { enqueued: true, duplicate: false }
            end
          ) do
            result =
              System::AnomalyWatchdog.call

            assert_equal false, result[:notified]
            assert_equal true,
                         result.dig(:recovery, :attempted)
          end
        end
      end

      assert_equal(
        [
          {
            reason: "layer1_stalled_watchdog"
          }
        ],
        requests
      )
    end

    private

    def with_stubbed(object, method_name, value)
      original =
        object.method(method_name)

      object.define_singleton_method(method_name) do |*args, **kwargs|
        value.respond_to?(:call) ? value.call(*args, **kwargs) : value
      end

      yield
    ensure
      object.define_singleton_method(method_name) do |*args, **kwargs, &block|
        original.call(*args, **kwargs, &block)
      end
    end
  end
end
