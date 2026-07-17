# frozen_string_literal: true

module Intelligence
  class SystemAssistant
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
      summary = @context[:summary] || {}
      layer1 = @context[:layer1] || {}
      queues = Array(@context[:queues])

      status =
        summary[:status].presence ||
        "indisponible"

      lag =
        layer1[:lag].to_i

      spent_lag =
        layer1[:spent_lag].to_i

      flow_lag =
        layer1[:flow_lag].to_i

      outputs_buffer =
        layer1.dig(
          :redis_buffers,
          :outputs
        ).to_i

      spent_buffer =
        layer1.dig(
          :redis_buffers,
          :spent
        ).to_i

      busy_queues =
        queues
          .select do |queue|
            queue[:size].to_i.positive? ||
              queue[:latency].to_f > 30
          end
          .sort_by do |queue|
            -queue[:size].to_i
          end
          .first(3)

      answer =
        +"État général de Tansa : statut #{status.upcase}. "

      answer <<
        "Layer1 présente un retard de #{lag} bloc(s). "

      answer <<
        "Le traitement asynchrone spent présente un retard de " \
        "#{spent_lag} bloc(s) et Exchange Flow un retard de " \
        "#{flow_lag} bloc(s). "

      answer <<
        "Les buffers Redis contiennent " \
        "#{outputs_buffer} output(s) et " \
        "#{spent_buffer} spent output(s)."

      if busy_queues.any?
        queue_text =
          busy_queues.map do |queue|
            "#{queue[:name]} " \
            "(#{queue[:size].to_i} job(s))"
          end.join(", ")

        answer <<
          " Queues actives : #{queue_text}."
      else
        answer <<
          " Aucune queue Sidekiq importante n'est en attente."
      end

      answer
    rescue StandardError => error
      Rails.logger.error(
        "[system_assistant] " \
        "#{error.class.name}: #{error.message}"
      )

      "L’état système est temporairement indisponible."
    end
  end
end
