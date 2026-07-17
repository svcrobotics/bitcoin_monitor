# frozen_string_literal: true

module Intelligence
  class OllamaAnomalyAssistant
    def self.call(question:, context:)
      new(
        question: question,
        context: context
      ).call
    end

    def initialize(question:, context:)
      @question = question.to_s
      @context = context || {}
    end

    def call
      anomalies =
        Array(context[:anomalies])

      return "Aucun problème détecté." if anomalies.empty?

      event =
        {
          transition: "manual",
          code: selected[:code],
          module: selected[:module],
          severity: selected[:severity],
          title: selected[:title],
          facts: selected[:facts],
          fingerprint: selected[:fingerprint]
        }

      Ollama::AdminAlertFormatter.call(event: event)
    rescue StandardError => error
      Rails.logger.warn(
        "[ollama_anomaly_assistant] " \
        "#{error.class}: #{error.message}"
      )

      "L’état des anomalies est temporairement indisponible."
    end

    private

    attr_reader :question, :context

    def selected
      @selected ||=
        Array(context[:anomalies])
          .sort_by do |anomaly|
            [
              anomaly[:severity].to_s == "critical" ? 0 : 1,
              anomaly[:module].to_s,
              anomaly[:code].to_s
            ]
          end
          .first
    end
  end
end
