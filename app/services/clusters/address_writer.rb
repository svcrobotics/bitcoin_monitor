# frozen_string_literal: true

module Clusters
  class AddressWriter
    def self.call(grouped_inputs:, height:, address_cache: nil)
      new(grouped_inputs: grouped_inputs, height: height, address_cache: address_cache).call
    end

    def initialize(grouped_inputs:, height:, address_cache: nil)
      @grouped_inputs = grouped_inputs
      @height = height.to_i
      @address_cache = address_cache
    end

    def call
      addresses = grouped_inputs.keys
      return [] if addresses.empty?

      upsert_addresses!(addresses)

      if address_cache.present?
        addresses.map { |addr| address_cache[addr] }.compact
      else
        Address.where(address: addresses).to_a
      end
    end

    private

    attr_reader :grouped_inputs, :height, :address_cache

    def upsert_addresses!(addresses)
      now = Time.current

      rows =
        addresses.map do |address|
          input_data = grouped_inputs.fetch(address)
          sent_sats = input_data[:total_value_sats].to_i

          {
            address: address,
            first_seen_height: height,
            last_seen_height: height,
            total_sent_sats: sent_sats,
            tx_count: 1,
            created_at: now,
            updated_at: now
          }
        end

      Address.upsert_all(
        rows,
        unique_by: :index_addresses_on_address,
        on_duplicate: Arel.sql(
          "first_seen_height = LEAST(addresses.first_seen_height, EXCLUDED.first_seen_height), " \
          "last_seen_height = GREATEST(addresses.last_seen_height, EXCLUDED.last_seen_height), " \
          "total_sent_sats = COALESCE(addresses.total_sent_sats, 0) + EXCLUDED.total_sent_sats, " \
          "tx_count = COALESCE(addresses.tx_count, 0) + 1, " \
          "updated_at = EXCLUDED.updated_at"
        )
      )
    end
  end
end