# frozen_string_literal: true

module AddressStats
  class RefreshSentFromClusterInputs
    BATCH_SIZE = ENV.fetch("ADDRESS_SENT_REFRESH_BATCH_SIZE", "5000").to_i

    def self.call(addresses: nil)
      new(addresses: addresses).call
    end

    def initialize(addresses:)
      @addresses = Array(addresses).compact_blank.uniq if addresses.present?
      @updated = 0
    end

    def call
      if @addresses.present?
        refresh_addresses(@addresses)
      else
        refresh_all
      end

      {
        ok: true,
        updated: @updated
      }
    end

    private

    def refresh_all
      Address
        .where.not(address: [nil, ""])
        .select(:address)
        .find_in_batches(batch_size: BATCH_SIZE) do |batch|
          refresh_addresses(batch.map(&:address))
        end
    end

    def refresh_addresses(addresses)
      return if addresses.empty?

      sent_by_address =
        ClusterInput
          .where(address: addresses, spent: true)
          .group(:address)
          .sum(Arel.sql("(amount_btc * 100000000)::bigint"))

      addresses.each do |address|
        Address
          .where(address: address)
          .update_all(
            total_sent_sats: sent_by_address[address].to_i,
            updated_at: Time.current
          )

        @updated += 1
      end
    end
  end
end
