# frozen_string_literal: true

require "test_helper"

module Ollama
  class AdminAlertFormatterTest < ActiveSupport::TestCase
    test "uses a valid short ollama response" do
      formatter =
        AdminAlertFormatter.new(event: event)

      formatter.define_singleton_method(:ollama_message) do
        "Layer1 a 7 blocs de retard."
      end

      assert_equal "Layer1 a 7 blocs de retard.", formatter.call
    end

    test "falls back for empty response" do
      formatter =
        AdminAlertFormatter.new(event: event)

      formatter.define_singleton_method(:ollama_message) { "" }

      assert_match(/Layer1 a un retard critique/, formatter.call)
    end

    test "falls back for multiple paragraphs" do
      formatter =
        AdminAlertFormatter.new(event: event)

      formatter.define_singleton_method(:ollama_message) do
        "Layer1 est en retard.\n\nIl faut intervenir."
      end

      assert_match(/Layer1 a un retard critique/, formatter.call)
    end

    test "ollama does not decide severity" do
      formatter =
        AdminAlertFormatter.new(event: event.merge(severity: "warning"))

      formatter.define_singleton_method(:ollama_message) do
        "Layer1 signale un retard."
      end

      assert_equal "Layer1 signale un retard.", formatter.call
    end

    private

    def event
      {
        transition: "new",
        code: "layer1_lag_critical",
        module: "layer1",
        severity: "critical",
        title: "Layer1 a un retard critique",
        facts: {
          lag_blocks: 7
        },
        fingerprint: "layer1:lag_critical"
      }
    end
  end
end
