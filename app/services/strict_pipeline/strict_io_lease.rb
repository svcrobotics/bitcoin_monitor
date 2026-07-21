# frozen_string_literal: true

require "securerandom"

module StrictPipeline
  class StrictIoLease
    KEY = "strict_io_owner"
    OWNERS = %w[layer1 cluster cluster_transaction_projection].freeze
    DEFAULT_TTL_SECONDS = 900

    COMPATIBILITY = {
      StrictIoMode::SERIALIZED => {
        "layer1" => [],
        "cluster" => [],
        "cluster_transaction_projection" => []
      }.freeze,
      StrictIoMode::CONCURRENT_SSD => {
        "layer1" => ["cluster"].freeze,
        "cluster" => ["layer1"].freeze,
        "cluster_transaction_projection" => []
      }.freeze
    }.freeze

    SERIALIZED_ACQUIRE_SCRIPT = <<~LUA
      local key = KEYS[1]
      local owner = ARGV[1]
      local token = ARGV[2]
      local acquired_at = ARGV[3]
      local expires_at = ARGV[4]
      local now_ms = tonumber(ARGV[5])
      local expires_at_ms = tonumber(ARGV[6])
      local ttl_ms = tonumber(ARGV[7])
      local owners = { "layer1", "cluster", "cluster_transaction_projection" }

      for _, active_owner in ipairs(owners) do
        local active_expires_at_ms = tonumber(
          redis.call(
            "HGET",
            key,
            active_owner .. ":expires_at_ms"
          ) or "0"
        )

        if active_expires_at_ms > now_ms then
          return {
            0,
            active_owner,
            redis.call("HGET", key, active_owner .. ":token") or "",
            tostring(active_expires_at_ms)
          }
        end
      end

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

    SERIALIZED_RENEW_SCRIPT = <<~LUA
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

    SERIALIZED_RELEASE_SCRIPT = <<~LUA
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

    CONCURRENT_ACQUIRE_SCRIPT = <<~LUA
      local key = KEYS[1]
      local owner = ARGV[1]
      local token = ARGV[2]
      local acquired_at = ARGV[3]
      local expires_at = ARGV[4]
      local now_ms = tonumber(ARGV[5])
      local expires_at_ms = tonumber(ARGV[6])
      local compatible_csv = ARGV[7]
      local owners = { "layer1", "cluster", "cluster_transaction_projection" }

      local legacy_owner = redis.call("HGET", key, "owner")
      local legacy_expires_at_ms = tonumber(
        redis.call("HGET", key, "expires_at_ms") or "0"
      )

      if legacy_owner and legacy_expires_at_ms > now_ms then
        return {
          0,
          legacy_owner,
          redis.call("HGET", key, "token") or "",
          tostring(legacy_expires_at_ms)
        }
      elseif legacy_owner then
        redis.call(
          "HDEL",
          key,
          "owner",
          "token",
          "acquired_at",
          "expires_at",
          "expires_at_ms"
        )
      end

      local function field(active_owner, suffix)
        return active_owner .. ":" .. suffix
      end

      local function remove_owner(active_owner)
        redis.call(
          "HDEL",
          key,
          field(active_owner, "token"),
          field(active_owner, "acquired_at"),
          field(active_owner, "expires_at"),
          field(active_owner, "expires_at_ms")
        )
      end

      local function compatible(active_owner)
        if compatible_csv == "" then
          return false
        end

        return string.find(
          "," .. compatible_csv .. ",",
          "," .. active_owner .. ",",
          1,
          true
        ) ~= nil
      end

      for _, active_owner in ipairs(owners) do
        local active_expires_at_ms = tonumber(
          redis.call("HGET", key, field(active_owner, "expires_at_ms")) or "0"
        )

        if active_expires_at_ms > 0 and active_expires_at_ms <= now_ms then
          remove_owner(active_owner)
        elseif active_expires_at_ms > now_ms and not compatible(active_owner) then
          return {
            0,
            active_owner,
            redis.call("HGET", key, field(active_owner, "token")) or "",
            tostring(active_expires_at_ms)
          }
        end
      end

      redis.call(
        "HSET",
        key,
        field(owner, "token"), token,
        field(owner, "acquired_at"), acquired_at,
        field(owner, "expires_at"), expires_at,
        field(owner, "expires_at_ms"), tostring(expires_at_ms)
      )

      local max_expires_at_ms = expires_at_ms
      for _, active_owner in ipairs(owners) do
        local active_expires_at_ms = tonumber(
          redis.call("HGET", key, field(active_owner, "expires_at_ms")) or "0"
        )
        if active_expires_at_ms > max_expires_at_ms then
          max_expires_at_ms = active_expires_at_ms
        end
      end
      redis.call("PEXPIREAT", key, max_expires_at_ms)

      return { 1, owner, token, tostring(expires_at_ms) }
    LUA

    CONCURRENT_RENEW_SCRIPT = <<~LUA
      local key = KEYS[1]
      local owner = ARGV[1]
      local token = ARGV[2]
      local expires_at = ARGV[3]
      local expires_at_ms = tonumber(ARGV[4])
      local now_ms = tonumber(ARGV[5])
      local owners = { "layer1", "cluster", "cluster_transaction_projection" }

      local function field(active_owner, suffix)
        return active_owner .. ":" .. suffix
      end

      if redis.call("HGET", key, field(owner, "token")) ~= token then
        return 0
      end

      local current_expires_at_ms = tonumber(
        redis.call("HGET", key, field(owner, "expires_at_ms")) or "0"
      )
      if current_expires_at_ms <= now_ms then
        return 0
      end

      redis.call(
        "HSET",
        key,
        field(owner, "expires_at"), expires_at,
        field(owner, "expires_at_ms"), tostring(expires_at_ms)
      )

      local max_expires_at_ms = expires_at_ms
      for _, active_owner in ipairs(owners) do
        local active_expires_at_ms = tonumber(
          redis.call("HGET", key, field(active_owner, "expires_at_ms")) or "0"
        )

        if active_owner ~= owner and
           active_expires_at_ms > 0 and
           active_expires_at_ms <= now_ms then
          redis.call(
            "HDEL",
            key,
            field(active_owner, "token"),
            field(active_owner, "acquired_at"),
            field(active_owner, "expires_at"),
            field(active_owner, "expires_at_ms")
          )
        elseif active_expires_at_ms > max_expires_at_ms then
          max_expires_at_ms = active_expires_at_ms
        end
      end
      redis.call("PEXPIREAT", key, max_expires_at_ms)

      return 1
    LUA

    CONCURRENT_RELEASE_SCRIPT = <<~LUA
      local key = KEYS[1]
      local owner = ARGV[1]
      local token = ARGV[2]
      local now_ms = tonumber(ARGV[3])
      local owners = { "layer1", "cluster", "cluster_transaction_projection" }

      local function field(active_owner, suffix)
        return active_owner .. ":" .. suffix
      end

      if redis.call("HGET", key, field(owner, "token")) ~= token then
        return 0
      end

      redis.call(
        "HDEL",
        key,
        field(owner, "token"),
        field(owner, "acquired_at"),
        field(owner, "expires_at"),
        field(owner, "expires_at_ms")
      )

      local max_expires_at_ms = 0
      for _, active_owner in ipairs(owners) do
        local active_expires_at_ms = tonumber(
          redis.call("HGET", key, field(active_owner, "expires_at_ms")) or "0"
        )
        if active_expires_at_ms > now_ms and active_expires_at_ms > max_expires_at_ms then
          max_expires_at_ms = active_expires_at_ms
        end
      end

      if max_expires_at_ms > 0 then
        redis.call("PEXPIREAT", key, max_expires_at_ms)
      else
        redis.call("DEL", key)
      end

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
      currents.first
    end

    def self.currents
      new.currents
    end

    def self.owned_by?(owner)
      currents.any? { |lease| lease.owner == owner.to_s }
    end

    def self.compatible_with_current?(owner)
      new.compatible_with_current?(owner)
    end

    def self.compatible_owners?(owner, active_owners)
      new.compatible_owners?(owner, active_owners)
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
      mode = StrictIoMode.current(logger: @logger)

      result =
        if mode == StrictIoMode::CONCURRENT_SSD
          redis_eval(
            CONCURRENT_ACQUIRE_SCRIPT,
            keys: [KEY],
            argv: [
              owner,
              token,
              now.iso8601(6),
              expires_at.iso8601(6),
              milliseconds(now),
              milliseconds(expires_at),
              compatible_owners(owner, mode).join(",")
            ]
          )
        else
          redis_eval(
            SERIALIZED_ACQUIRE_SCRIPT,
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
        end

      if result.first.to_i == 1
        lease =
          Lease.new(
            owner: owner,
            token: token,
            acquired_at: now,
            expires_at: expires_at
          )

        log("strict_io_lease_acquired", lease: lease, mode: mode)
        return lease
      end

      log(
        "strict_io_lease_denied",
        owner: owner,
        mode: mode,
        current_owner: result[1],
        current_token: result[2],
        current_expires_at_ms: result[3]
      )

      nil
    end

    def renew(owner:, token:, ttl_seconds: self.class.ttl_seconds_default)
      owner = normalize_owner(owner)
      expires_at = Time.current + ttl_seconds.to_i.seconds
      mode = StrictIoMode.current(logger: @logger)

      result =
        if mode == StrictIoMode::CONCURRENT_SSD
          redis_eval(
            CONCURRENT_RENEW_SCRIPT,
            keys: [KEY],
            argv: [
              owner,
              token,
              expires_at.iso8601(6),
              milliseconds(expires_at),
              milliseconds(Time.current)
            ]
          )
        else
          redis_eval(
            SERIALIZED_RENEW_SCRIPT,
            keys: [KEY],
            argv: [
              owner,
              token,
              expires_at.iso8601(6),
              milliseconds(expires_at),
              ttl_seconds.to_i * 1000
            ]
          )
        end

      result.to_i == 1
    end

    def release(owner:, token:)
      owner = normalize_owner(owner)
      mode = StrictIoMode.current(logger: @logger)

      result =
        if mode == StrictIoMode::CONCURRENT_SSD
          redis_eval(
            CONCURRENT_RELEASE_SCRIPT,
            keys: [KEY],
            argv: [owner, token, milliseconds(Time.current)]
          )
        else
          redis_eval(
            SERIALIZED_RELEASE_SCRIPT,
            keys: [KEY],
            argv: [owner, token]
          )
        end

      released = result.to_i == 1

      if released
        log("strict_io_lease_released", owner: owner, token: token)
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
      currents.first
    end

    def currents
      payload = redis_call { |redis| redis.hgetall(KEY) }
      now_ms = milliseconds(Time.current)

      legacy_expires_at_ms = payload["expires_at_ms"].to_i
      if payload["owner"].present? && legacy_expires_at_ms > now_ms
        return [
          Lease.new(
            owner: payload["owner"],
            token: payload["token"],
            acquired_at: parse_time(payload["acquired_at"]),
            expires_at: parse_time(payload["expires_at"])
          )
        ]
      end

      OWNERS.filter_map do |owner|
        expires_at_ms = payload[lease_field(owner, "expires_at_ms")].to_i
        next unless expires_at_ms > now_ms

        Lease.new(
          owner: owner,
          token: payload[lease_field(owner, "token")],
          acquired_at: parse_time(payload[lease_field(owner, "acquired_at")]),
          expires_at: parse_time(payload[lease_field(owner, "expires_at")])
        )
      end
    end

    def compatible_with_current?(owner)
      owner = normalize_owner(owner)
      compatible_owners?(owner, currents.map(&:owner))
    end

    def compatible_owners?(owner, active_owners)
      owner = normalize_owner(owner)
      mode = StrictIoMode.current(logger: @logger)
      allowed = compatible_owners(owner, mode)

      Array(active_owners).map(&:to_s).all? do |active_owner|
        allowed.include?(active_owner)
      end
    end

    private

    def compatible_owners(owner, mode)
      COMPATIBILITY.fetch(mode).fetch(owner)
    end

    def lease_field(owner, suffix)
      "#{owner}:#{suffix}"
    end

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
