# app/services/intelligence/providers/openai.rb
# frozen_string_literal: true

module Intelligence
  module Providers
    class Openai
      def self.chat_content(messages:, model: ENV.fetch("OPENAI_MODEL", "gpt-4o-mini"))
        input = <<~PROMPT
          Return JSON only.

          The JSON object must use exactly this schema:
          {"answer":"string"}

          #{messages.map { |message|
            "#{message[:role].to_s.upcase}:\n#{message[:content]}"
          }.join("\n\n")}
        PROMPT

        result = OpenaiClient
          .new(model: model)
          .json_response!(
            schema_name: "tansa_intelligence_answer",
            input: input,
            max_output_tokens: 500
          )

        (result["answer"] || result[:answer] || result.values.first).to_s.strip
      end
    end
  end
end