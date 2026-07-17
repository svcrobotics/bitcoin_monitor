# frozen_string_literal: true

module Clusters
  class AddressWriter
    def self.call(grouped_inputs:, height:, address_cache: nil)
      new(
        grouped_inputs: grouped_inputs,
        height: height,
        address_cache: address_cache
      ).call
    end

    def initialize(grouped_inputs:, height:, address_cache: nil)
      @grouped_inputs = grouped_inputs
      @height = height.to_i
      @address_cache = address_cache
    end

    def call
      addresses = grouped_inputs.keys.compact_blank.uniq
      return [] if addresses.empty?

      upsert_addresses!(addresses)

      records =
        Address
          .where(address: addresses)
          .to_a

      refresh_cache!(records)

      records
    end

    private

    attr_reader :grouped_inputs, :height, :address_cache

    def upsert_addresses!(addresses)
      now = Time.current

      rows =
        addresses.map do |address|
          {
            address: address,
            first_seen_height: height,
            last_seen_height: height,
            tx_count: 1,
            created_at: now,
            updated_at: now
          }
        end

      Address.upsert_all(
        rows,
        unique_by: :index_addresses_on_address,
        on_duplicate: Arel.sql(
          "first_seen_height = " \
          "LEAST(addresses.first_seen_height, EXCLUDED.first_seen_height), " \
          "last_seen_height = " \
          "GREATEST(addresses.last_seen_height, EXCLUDED.last_seen_height), " \
          "updated_at = EXCLUDED.updated_at"
        )
      )

      # Important :
      # ClusterMerger est le propriétaire de l'affectation des clusters
      # pour un groupe multi-input.
      #
      # Ne pas créer ici un cluster temporaire par adresse :
      # cela provoquerait ensuite des centaines de fusions et suppressions
      # inutiles dans ClusterMerger.
    end

    def refresh_cache!(records)
      return unless address_cache

      records.each do |record|
        address_cache[record.address] = record
      end
    end
  end
end
