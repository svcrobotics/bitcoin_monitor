# frozen_string_literal: true

module Search
  class QuestionDefinitionIndexer
    INDEX = "question_definitions"

    def self.call
      new.call
    end

    def call
      return { ok: false, error: "Elasticsearch client missing" } unless client

      QuestionDefinition.active.find_each do |question|
        client.index(
          index: INDEX,
          id: question.key,
          body: body_for(question)
        )
      end

      { ok: true, indexed: QuestionDefinition.active.count }
    end

    private

    def client
      ELASTICSEARCH_CLIENT
    rescue NameError
      nil
    end

    def body_for(question)
      {
        key: question.key,
        question: question.question,
        module_name: question.module_name,
        tier: question.tier,
        intent: question.intent,
        answer_service: question.answer_service,
        historical_path: question.historical_path,
        active: question.active,
        position: question.position,
        metadata: question.metadata,
        searchable_text: [
          question.question,
          question.module_name,
          question.tier,
          question.intent
        ].join(" ")
      }
    end
  end
end
