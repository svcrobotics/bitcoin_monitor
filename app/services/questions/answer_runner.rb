# frozen_string_literal: true

module Questions
  class AnswerRunner
    def self.call(question)
      new(question).call
    end

    def initialize(question)
      @question = question
    end

    def call
      service_class.call(question: @question)
    end

    private

    attr_reader :question

    def service_class
      question.answer_service.constantize
    rescue NameError => e
      raise NameError, "Unknown answer_service=#{question.answer_service.inspect} for question=#{question.key}: #{e.message}"
    end
  end
end