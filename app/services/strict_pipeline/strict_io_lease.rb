# frozen_string_literal: true

require "securerandom"

module StrictPipeline
  class StrictIoLease
    KEY = "strict_io_owner"
    OWNERS = %w[layer1 cluster cluster_transaction_projection].freeze
    DEFAULT_TTL_SECONDS = 900

    ACQUIRE_SCRIPT = <<~LUA
      local key = KEYS[1]
      local owner = ARGV[1]
      local token = ARGV[2]
      local acquired_at = ARGV[3]
      local expires_at = ARGV[4]
      local now_ms = tonumber(ARGV[5])
      local expires_at_ms = tonumber(ARGV[6])
      local ttl_ms = tonumber(ARGV[7])

      local current_owner = redis.call("HGET", key, "owner")
      local current_expires_at_ms = tonumber(redis.call("HGET", key, "expires_at_ms") or "0")

      if current_owner and current_expires_at_ms > now_ms then
        return {
          0,
          current_owner,
          redis.call("HGET", key, "token") or "",
          tostring(current_expires_at_ms)
        }
      end

      redis.call("DEL", key)
      redis.call(
        "HSET",
        key,
        "owner", owner,
        "token", token,
        "acquired_at", acquired_at,
        "expires_at", expires_at,
        "expires_at_ms", tostring(expires_at_ms)
      )
      redis.call("PEXPIRE", key, ttl_ms)

      return { 1, owner, token, tostring(expires_at_ms) }
    LUA

    RENEW_SCRIPT = <<~LUA
      local key = KEYS[1]
      local owner = ARGV[1]
      local token = ARGV[2]
      local expires_at = ARGV[3]
      local expires_at_ms = tonumber(ARGV[4])
      local ttl_ms = tonumber(ARGV[5])

      if redis.call("HGET", key, "owner") ~= owner then
        return 0
      end

      if redis.call("HGET", key, "token") ~= token then
        return 0
      end

      redis.call(
        "HSET",
        key,
        "expires_at", expires_at,
        "expires_at_ms", tostring(expires_at_ms)
      )
      redis.call("PEXPIRE", key, ttl_ms)

      return 1
    LUA

    RELEASE_SCRIPT = <<~LUA
      local key = KEYS[1]
      local owner = ARGV[1]
      local token = ARGV[2]

      if redis.call("HGET", key, "owner") ~= owner then
        return 0
      end

      if redis.call("HGET", key, "token") ~= token then
        return 0
      end

      redis.call("DEL", key)
      return 1
    LUA

    Lease =
      Struct.new(
        :owner,
        :token,
        :acquired_at,
        :expires_at,
        keyword_init: true
      )

    def self.acquire(owner, ttl_seconds: ttl_seconds_default, logger: Rails.logger)
      new(logger: logger).acquire(owner, ttl_seconds: ttl_seconds)
    end

    def self.renew(owner:, token:, ttl_seconds: ttl_seconds_default, logger: Rails.logger)
      new(logger: logger).renew(owner: owner, token: token, ttl_seconds: ttl_seconds)
    end

    def self.release(owner:, token:, logger: Rails.logger)
      new(logger: logger).release(owner: owner, token: token)
    end

    def self.current
      new.current
    end

    def self.owned_by?(owner)
      current&.owner.to_s == owner.to_s
    end

    def self.clear!
      Sidekiq.redis { |redis| redis.del(KEY) }
    end

    def self.ttl_seconds_default
      Integer(
        ENV.fetch(
          "STRICT_IO_LEASE_TTL_SECONDS",
          DEFAULT_TTL_SECONDS.to_s
        )
      )
    end

    def initialize(redis: nil, logger: Rails.logger)
      @redis = redis
      @logger = logger
    end

    def acquire(owner, ttl_seconds: self.class.ttl_seconds_default)
      owner = normalize_owner(owner)
      token = SecureRandom.uuid
      now = Time.current
      expires_at = now + ttl_seconds.to_i.seconds

      result =
        redis_eval(
          ACQUIRE_SCRIPT,
          keys: [KEY],
          argv: [
            owner,
            token,
            now.iso8601(6),
            expires_at.iso8601(6),
            milliseconds(now),
            milliseconds(expires_at),
            ttl_seconds.to_i * 1000
          ]
        )

      if result.first.to_i == 1
        lease =
          Lease.new(
            owner: owner,
            token: token,
            acquired_at: now,
            expires_at: expires_at
          )

        log("strict_io_lease_acquired", lease: lease)
        return lease
      end

      log(
        "strict_io_lease_denied",
        owner: owner,
        current_owner: result[1],
        current_token: result[2],
        current_expires_at_ms: result[3]
      )

      nil
    end

    def renew(owner:, token:, ttl_seconds: self.class.ttl_seconds_default)
      owner = normalize_owner(owner)
      expires_at = Time.current + ttl_seconds.to_i.seconds

      result =
        redis_eval(
          RENEW_SCRIPT,
          keys: [KEY],
          argv: [
            owner,
            token,
            expires_at.iso8601(6),
            milliseconds(expires_at),
            ttl_seconds.to_i * 1000
          ]
        )

      result.to_i == 1
    end

    def release(owner:, token:)
      owner = normalize_owner(owner)

      result =
        redis_eval(
          RELEASE_SCRIPT,
          keys: [KEY],
          argv: [owner, token]
        )

      released = result.to_i == 1

      if released
        log(
          "strict_io_lease_released",
          owner: owner,
          token: token
        )
      else
        log(
          "strict_io_lease_denied",
          owner: owner,
          token: token,
          action: "release"
        )
      end

      released
    end

    def current
      payload =
        redis_call do |redis|
          redis.hgetall(KEY)
        end

      return nil if payload.blank?
      return nil if payload["expires_at_ms"].to_i <= milliseconds(Time.current)

      Lease.new(
        owner: payload["owner"],
        token: payload["token"],
        acquired_at: parse_time(payload["acquired_at"]),
        expires_at: parse_time(payload["expires_at"])
      )
    end

    private

    def normalize_owner(owner)
      normalized = owner.to_s
      return normalized if OWNERS.include?(normalized)

      raise ArgumentError, "unknown strict IO owner #{owner.inspect}"
    end

    def milliseconds(time)
      (time.to_f * 1000).round
    end

    def parse_time(value)
      Time.zone.parse(value) if value.present?
    end

    def redis_eval(script, keys:, argv:)
      redis_call do |redis|
        redis.call("EVAL", script, keys.size, *keys, *argv)
      end
    end

    def redis_call
      if @redis
        yield @redis
      else
        Sidekiq.redis { |redis| yield redis }
      end
    end

    def log(event, payload = {})
      fields =
        payload.flat_map do |key, value|
          if value.is_a?(Lease)
            [
              "owner=#{value.owner}",
              "token=#{value.token}",
              "acquired_at=#{value.acquired_at&.iso8601(6)}",
              "expires_at=#{value.expires_at&.iso8601(6)}"
            ]
          else
            ["#{key}=#{value}"]
          end
        end

      @logger.info("[strict_io] #{event} #{fields.join(' ')}")
    end
  end
end
