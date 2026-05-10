# app/services/blockchain/redis/client.rb
# frozen_string_literal: true

require "redis"

module Blockchain
  module Redis
    class Client
      def self.instance
        @instance ||= ::Redis.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0"))
      end
    end
  end
end