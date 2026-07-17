# frozen_string_literal: true

require "json"
require "net/http"

module Ollama
  class AdminAlertFormatter
    SYSTEM_PROMPT = <<~PROMPT.squish
      Tu es la voix locale du système d’alerte de Tansa.
      Tansa a déjà détecté et vérifié l’anomalie.
      Tu dois uniquement la formuler clairement.
      Règles :
      - Réponds en français.
      - Produis une seule phrase.
      - Sois extrêmement concis.
      - Mentionne le module concerné.
      - Mentionne uniquement le problème observé.
      - Utilise seulement les faits fournis.
      - Ne suppose jamais une cause.
      - Ne donne aucun conseil.
      - Ne propose aucune correction.
      - Ne cite aucun module sain.
      - N’ajoute ni introduction ni conclusion.
    PROMPT

    MAX_LENGTH = 180

    def self.call(event:)
      new(event: event).call
    end

    def initialize(event:)
      @event = event || {}
    end

    def call
      message =
        ollama_message

      clean(message).presence ||
        fallback
    rescue StandardError => error
      Rails.logger.warn(
        "[ollama_admin_alert_formatter] " \
        "#{error.class}: #{error.message}"
      )

      fallback
    end

    private

    attr_reader :event

    def ollama_message
      response =
        http.request(request)

      return nil unless response.is_a?(Net::HTTPSuccess)

      payload =
        JSON.parse(response.body)

      payload.dig("message", "content").to_s
    rescue Net::OpenTimeout,
           Net::ReadTimeout,
           Errno::ECONNREFUSED,
           JSON::ParserError
      nil
    end

    def http
      uri =
        endpoint

      Net::HTTP.new(uri.host, uri.port).tap do |client|
        client.use_ssl = uri.scheme == "https"
        client.open_timeout =
          Float(
            ENV.fetch("OLLAMA_ALERT_OPEN_TIMEOUT_SECONDS", "1.5")
          )
        client.read_timeout =
          Float(
            ENV.fetch("OLLAMA_ALERT_READ_TIMEOUT_SECONDS", "3")
          )
      end
    end

    def request
      Net::HTTP::Post.new(endpoint).tap do |request|
        request["Content-Type"] = "application/json"
        request.body =
          {
            model: ENV.fetch("OLLAMA_MODEL", "qwen2.5:3b"),
            stream: false,
            messages: [
              {
                role: "system",
                content: SYSTEM_PROMPT
              },
              {
                role: "user",
                content: JSON.generate(event_payload)
              }
            ],
            options: {
              temperature: 0.1,
              num_predict: 80
            }
          }.to_json
      end
    end

    def endpoint
      URI(
        ENV.fetch(
          "OLLAMA_CHAT_URL",
          "http://127.0.0.1:11434/api/chat"
        )
      )
    end

    def event_payload
      {
        transition: event[:transition],
        code: event[:code],
        module: event[:module],
        severity: event[:severity],
        facts: event[:facts] || {}
      }
    end

    def clean(message)
      text =
        message.to_s.strip

      return nil if text.blank?
      return nil if text.include?("\n\n")

      text =
        text
          .lines
          .first
          .to_s
          .squish

      return nil if text.blank?
      return nil if text.length > MAX_LENGTH

      text
    end

    def fallback
      facts =
        event[:facts] || {}

      case event[:transition].to_s
      when "resolved"
        "#{module_label} progresse de nouveau."
      else
        metric =
          primary_fact_text(facts)

        [
          event[:title].presence || "#{module_label} signale une anomalie",
          metric
        ].compact.join(" : ")
      end
    end

    def module_label
      event[:module].to_s.presence || "Tansa"
    end

    def primary_fact_text(facts)
      key, value =
        facts.find { |_name, fact| fact.is_a?(Numeric) }

      return nil unless key

      "#{human_key(key)} #{value}"
    end

    def human_key(key)
      key.to_s.tr("_", " ")
    end
  end
end
