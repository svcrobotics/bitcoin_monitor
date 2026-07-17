# frozen_string_literal: true

require "net/http"
require "json"

module Intelligence
  module Providers
    class Ollama
      ENDPOINT =
        URI(
          ENV.fetch(
            "OLLAMA_CHAT_URL",
            "http://127.0.0.1:11434/api/chat"
          )
        )

      DEFAULT_MODEL =
        ENV.fetch(
          "OLLAMA_MODEL",
          "qwen2.5:3b"
        )

      def self.chat(messages:, model: DEFAULT_MODEL)
        http =
          Net::HTTP.new(
            ENDPOINT.host,
            ENDPOINT.port
          )

        http.use_ssl =
          ENDPOINT.scheme == "https"

        http.open_timeout =
          Integer(
            ENV.fetch(
              "OLLAMA_OPEN_TIMEOUT_SECONDS",
              "5"
            )
          )

        http.read_timeout =
          Integer(
            ENV.fetch(
              "OLLAMA_READ_TIMEOUT_SECONDS",
              "120"
            )
          )

        request =
          Net::HTTP::Post.new(ENDPOINT)

        request["Content-Type"] =
          "application/json"

        request.body =
          {
            model: model,
            messages: messages,
            stream: false,
            format: "json",
            keep_alive: "10m",

            options: {
              temperature: 0.1,
              num_predict: 160
            }
          }.to_json

        response =
          http.request(request)

        unless response.is_a?(
          Net::HTTPSuccess
        )
          return {
            "error" => true,
            "message" =>
              "Ollama HTTP #{response.code}: " \
              "#{response.body}"
          }
        end

        JSON.parse(response.body)
      rescue Net::OpenTimeout,
             Net::ReadTimeout => error

        {
          "error" => true,
          "message" =>
            "Ollama timeout: " \
            "#{error.class.name}"
        }
      rescue Errno::ECONNREFUSED => error
        {
          "error" => true,
          "message" =>
            "Ollama indisponible sur " \
            "#{ENDPOINT}: #{error.message}"
        }
      rescue JSON::ParserError => error
        {
          "error" => true,
          "message" =>
            "Réponse Ollama invalide: " \
            "#{error.message}"
        }
      rescue StandardError => error
        {
          "error" => true,
          "message" =>
            "#{error.class.name}: " \
            "#{error.message}"
        }
      end

      def self.chat_content(
        messages:,
        model: DEFAULT_MODEL
      )
        result =
          chat(
            messages: messages,
            model: model
          )

        return nil if result["error"]

        content =
          result
            .dig("message", "content")
            .to_s
            .strip

        return nil if content.blank?

        begin
          parsed =
            JSON.parse(content)

          answer =
            parsed["answer"] ||
            parsed[:answer]

          answer.to_s.strip.presence ||
            content
        rescue JSON::ParserError
          content
        end
      end
    end
  end
end
