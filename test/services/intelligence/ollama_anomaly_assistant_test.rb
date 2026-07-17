# frozen_string_literal: true

require "test_helper"

module Intelligence
  class OllamaAnomalyAssistantTest < ActiveSupport::TestCase
    test "returns no problem when anomaly snapshot is empty" do
      answer =
        OllamaAnomalyAssistant.call(
          question: "Ollama état système",
          context: {
            anomalies: []
          }
        )

      assert_equal "Aucun problème détecté.", answer
    end

    test "formats the most severe anomaly" do
      with_stubbed(Ollama::AdminAlertFormatter, :call, "Layer1 a un retard critique.") do
        answer =
          OllamaAnomalyAssistant.call(
            question: "Ollama problème",
            context: {
              anomalies: [
                anomaly("actor_profile", "warning"),
                anomaly("layer1", "critical")
              ]
            }
          )

        assert_equal "Layer1 a un retard critique.", answer
      end
    end

    test "router only sends explicit ollama commands to anomaly path" do
      with_stubbed(System::AnomalySnapshot, :call, { anomalies: [] }) do
        route =
          Router.call("Ollama résume")

        assert_equal :ollama_anomaly, route[:intent]
      end

      route =
        Router.call("résume le système")

      refute_equal :ollama_anomaly, route[:intent]
    end

    private

    def anomaly(mod, severity)
      {
        code: "#{mod}_problem",
        module: mod,
        severity: severity,
        title: "#{mod} problème",
        facts: {},
        fingerprint: "#{mod}:problem"
      }
    end

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
