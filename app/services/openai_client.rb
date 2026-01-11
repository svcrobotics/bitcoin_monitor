# frozen_string_literal: true
require "net/http"
require "json"
require "uri"

class OpenaiClient
  API_URL = "https://api.openai.com/v1/responses"

  def initialize(api_key: ENV.fetch("OPENAI_API_KEY"), model: ENV.fetch("OPENAI_MODEL", "gpt-4o-mini"))
    @api_key = api_key
    @model = model
  end

  def json_response!(schema_name:, input:, max_output_tokens: 700)
    uri = URI.parse(API_URL)

    req = Net::HTTP::Post.new(uri)
    req["Authorization"] = "Bearer #{@api_key}"
    req["Content-Type"]  = "application/json"

    # Responses API: "input" can be string or array; we keep it simple (string)
    body = {
      model: @model,
      input: input,
      max_output_tokens: max_output_tokens,
      # Ask for structured JSON output
      text: { format: { type: "json_object" } }
    }

    req.body = JSON.dump(body)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    res = http.request(req)
    raise "OpenAI error #{res.code}: #{res.body}" unless res.is_a?(Net::HTTPSuccess)

    parsed = JSON.parse(res.body)
    # Responses output text typically sits in output[...].content[...].text (depending)
    extract_json_text(parsed)
  end

  private

  def extract_json_text(parsed)
    # Defensive extraction (structure may evolve)
    output = parsed["output"] || []
    msg = output.find { |o| o["type"] == "message" } || output.first
    content = msg && msg["content"] || []
    text_item = content.find { |c| c["type"] == "output_text" } || content.first
    JSON.parse(text_item["text"])
  end
end
