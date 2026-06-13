# frozen_string_literal: true

module AddressStats
  class BackfillFromOutputs
    BATCH_SIZE = ENV.fetch("ADDRESS_STATS_BACKFILL_BATCH_SIZE", "1000").to_i

    def self.call(limit: nil)
      new(limit: limit).call
    end

    def initialize(limit: nil)
      @limit = limit&.to_i
      @updated = 0
    end

    def call
      scope = Address.order(:id)
      scope = scope.limit(@limit) if @limit

      scope.find_in_batches(batch_size: BATCH_SIZE).with_index do |batch, index|
        addresses = batch.map(&:address)

        received_by_address = UtxoOutput
          .where(address: addresses)
          .group(:address)
          .sum(Arel.sql("(amount_btc * 100000000)::bigint"))

        sent_by_address = ClusterInput
          .where(address: addresses, spent: true)
          .group(:address)
          .sum(Arel.sql("(amount_btc * 100000000)::bigint"))

        batch.each do |addr|
          received = received_by_address[addr.address].to_i
          sent = sent_by_address[addr.address].to_i

          addr.update_columns(
            total_received_sats: received,
            total_sent_sats: sent,
            updated_at: Time.current
          )

          @updated += 1
        end

        puts "[address_stats_backfill] batch=#{index + 1} updated=#{@updated}"
      end

      {
        ok: true,
        updated: @updated
      }
    end
  end
end