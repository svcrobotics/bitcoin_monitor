# frozen_string_literal: true

require "net/http"
require "json"

module Ai
  class Embedding
    MODEL = "text-embedding-3-small"
    URI_ENDPOINT = URI("https://api.openai.com/v1/embeddings")

    def self.call(input)
      new(input).call
    end

    def initialize(input)
      @input = input.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
    end

    def call
      attempts = 0

      begin
        attempts += 1
        request_embedding
      rescue StandardError => e
        raise if attempts >= 5

        warn "[embedding] retry #{attempts}/5: #{e.message}"
        sleep(attempts * 2)
        retry
      end
    end

    private

    def request_embedding
      request = Net::HTTP::Post.new(URI_ENDPOINT)
      request["Authorization"] = "Bearer #{ENV.fetch("OPENAI_API_KEY").strip}"
      request["Content-Type"] = "application/json"

      request.body = {
        model: MODEL,
        input: @input
      }.to_json

      response = Net::HTTP.start(
        URI_ENDPOINT.hostname,
        URI_ENDPOINT.port,
        use_ssl: true,
        open_timeout: 10,
        read_timeout: 60
      ) do |http|
        http.request(request)
      end

      body = JSON.parse(response.body)

      unless response.is_a?(Net::HTTPSuccess)
        raise body.inspect
      end

      body.dig("data", 0, "embedding")
    end
  end
end