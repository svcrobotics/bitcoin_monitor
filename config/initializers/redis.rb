# frozen_string_literal: true

require "redis"

REDIS_URL = ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0")

REDIS = Redis.new(url: REDIS_URL)