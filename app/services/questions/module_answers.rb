# frozen_string_literal: true

module Questions
  class ModuleAnswers
    def self.call(module_name:, tier: nil)
      new(module_name: module_name, tier: tier).call
    end

    def initialize(module_name:, tier: nil)
      @module_name = module_name
      @tier = tier
    end

    def call
      scope = QuestionDefinition.active.for_module(module_name).ordered
      scope = scope.for_tier(tier) if tier.present?

      scope.map do |question|
        Questions::AnswerRunner.call(question)
      rescue StandardError => e
        error_answer(question, e)
      end
    end

    private

    attr_reader :module_name, :tier

    def error_answer(question, error)
      {
        question: question.question,
        key: question.key,
        module_name: question.module_name,
        tier: question.tier,
        verdict: "Réponse indisponible",
        answer: "Cette réponse n’a pas pu être calculée pour le moment.",
        evidence: [],
        interpretation: nil,
        methodology: nil,
        confidence: "faible",
        updated_at: Time.current,
        historical_path: question.historical_path,
        error: error.message
      }
    end
  end
end
