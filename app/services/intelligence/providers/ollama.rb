# app/services/intelligence/providers/ollama.rb

require "net/http"
require "json"

module Intelligence
  module Providers
    class Ollama
      ENDPOINT = URI("http://127.0.0.1:11434/api/chat")
      DEFAULT_MODEL = "qwen2.5:7b"

      def self.chat(messages:, model: DEFAULT_MODEL)
        http = Net::HTTP.new(ENDPOINT.host, ENDPOINT.port)
        http.open_timeout = 10
        http.read_timeout = 300

        request = Net::HTTP::Post.new(ENDPOINT)
        request["Content-Type"] = "application/json"
        request.body = {
          model: model,
          messages: messages,
          stream: false,
          options: {
            temperature: 0.2,
            num_predict: 300
          }
        }.to_json

        response = http.request(request)

        unless response.is_a?(Net::HTTPSuccess)
          raise "Ollama error #{response.code}: #{response.body}"
        end

        JSON.parse(response.body)
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        {
          "error" => true,
          "message" => "Ollama timeout: #{e.class}"
        }
      rescue Errno::ECONNREFUSED
        {
          "error" => true,
          "message" => "Ollama ne répond pas sur #{ENDPOINT}"
        }
      end

      def self.chat_content(messages:, model: DEFAULT_MODEL)
        result = chat(messages:, model:)

        case result
        when String
          result.strip
        when Hash
          result.dig("message", "content").to_s.strip
        else
          result.to_s
        end
      end
    end
  end
end