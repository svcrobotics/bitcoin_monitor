# frozen_string_literal: true

require "digest"
require "json"

module ActorBehaviors
  class ProfileFingerprint
    KEYS = [
      :cluster_id,
      :balance_btc,
      :total_received_btc,
      :total_sent_btc,
      :net_btc,
      :tx_count,
      :inflow_count,
      :outflow_count,
      :first_seen_at,
      :last_seen_at,
      :first_seen_height,
      :last_seen_height,
      :last_computed_height,
      :cluster_composition_version,
      :profile_version
    ].freeze

    DECIMAL_KEYS = %i[
      balance_btc
      total_received_btc
      total_sent_btc
      net_btc
    ].freeze

    INTEGER_KEYS = %i[
      cluster_id
      tx_count
      inflow_count
      outflow_count
      first_seen_height
      last_seen_height
      last_computed_height
      cluster_composition_version
    ].freeze

    TIME_KEYS = %i[
      first_seen_at
      last_seen_at
    ].freeze

    def self.call(profile)
      new(profile).call
    end

    def self.payload(profile)
      new(profile).payload
    end

    def initialize(profile)
      @profile = profile
    end

    def call
      Digest::SHA256.hexdigest(
        JSON.generate(payload)
      )
    end

    def payload
      KEYS.map do |key|
        [
          key.to_s,
          normalized_value(key)
        ]
      end
    end

    private

    attr_reader :profile

    def normalized_value(key)
      value =
        source_value(key)

      return nil if value.nil?

      if DECIMAL_KEYS.include?(key)
        normalize_decimal(value)
      elsif INTEGER_KEYS.include?(key)
        Integer(value)
      elsif TIME_KEYS.include?(key)
        normalize_time(value)
      else
        value.to_s
      end
    end

    def source_value(key)
      case key
      when :profile_version
        profile.traits.to_h["profile_version"]
      when :first_seen_height
        profile.traits.to_h["first_seen_height"]
      when :last_seen_height
        profile.traits.to_h["last_seen_height"]
      else
        profile.public_send(key)
      end
    end

    def normalize_decimal(value)
      BigDecimal(value.to_s).to_s("F")
    end

    def normalize_time(value)
      value
        .to_time
        .utc
        .iso8601(6)
    end
  end
end
