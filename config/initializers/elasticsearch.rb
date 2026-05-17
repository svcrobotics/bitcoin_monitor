# frozen_string_literal: true

require "elasticsearch"

ELASTICSEARCH_CLIENT = Elasticsearch::Client.new(
  url: ENV.fetch("ELASTICSEARCH_URL", "http://localhost:9200"),
  log: Rails.env.development?
)
