# frozen_string_literal: true

require "faraday"

module ClickHouse
  class Client
    DEFAULT_URL = "http://127.0.0.1:8123"

    def initialize(
      url: ENV.fetch("CLICKHOUSE_URL", DEFAULT_URL),
      database: ENV.fetch("CLICKHOUSE_DATABASE", "bitcoin_monitor")
    )
      @url = url
      @database = database
    end

    def execute(sql)
      response = connection.post("/") do |req|
        req.params["database"] = database
        req.body = sql
      end

      return response.body if response.success?

      raise Error, "ClickHouse error #{response.status}: #{response.body}"
    end

    private

    attr_reader :url, :database

    def connection
      @connection ||= Faraday.new(url: url)
    end
  end

  class Error < StandardError; end
end