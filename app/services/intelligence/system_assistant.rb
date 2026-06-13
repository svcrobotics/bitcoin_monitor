# app/services/intelligence/system_assistant.rb
# frozen_string_literal: true

module Intelligence
  class SystemAssistant
    def self.call(question:, context:)
      fallback_answer(context)
    end

    def self.fallback_answer(context)
      summary = context[:summary] || {}
      layer1 = context[:layer1] || {}
      queues = Array(context[:queues])

      critical_queues = queues.select { |q| q[:size].to_i > 1000 }
      warning_queues = queues.select { |q| q[:size].to_i > 100 && q[:size].to_i <= 1000 }
      latency_queues = queues.select { |q| q[:latency].to_f > 300 }

      status =
        if critical_queues.any?
          "CRITICAL"
        elsif warning_queues.any? || latency_queues.any? || layer1[:lag].to_i.positive?
          "WARNING"
        else
          summary[:status].to_s.upcase.presence || "OK"
        end

      answer = +"État général : le système est en #{status}."

      if layer1[:lag].to_i.positive?
        answer << "\n\nLayer 1 : retard de #{layer1[:lag].to_i} bloc(s)."
      else
        answer << "\n\nLayer 1 : aucun retard détecté."
      end

      if critical_queues.any?
        list = critical_queues.first(3).map { |q| "#{q[:name]} (#{q[:size].to_i} jobs)" }.join(", ")
        answer << "\n\nBacklog critique : #{list}."
      elsif warning_queues.any?
        list = warning_queues.first(3).map { |q| "#{q[:name]} (#{q[:size].to_i} jobs)" }.join(", ")
        answer << "\n\nBacklog à surveiller : #{list}."
      elsif latency_queues.any?
        list = latency_queues.first(3).map { |q| "#{q[:name]} (#{q[:latency].to_f.round(1)}s)" }.join(", ")
        answer << "\n\nLatence élevée : #{list}."
      else
        answer << "\n\nQueues : aucun backlog critique détecté."
      end

      answer
    end
  end
end