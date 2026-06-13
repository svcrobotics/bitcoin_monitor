# frozen_string_literal: true

module Actors
  class SyncExchangeCoreAddressesFromProfiles
    SOURCE = "actor_profile_exchange_like"
    BATCH_SIZE = 10_000

    def self.call
      new.call
    end

    def initialize
      @inserted = 0
      @clusters = 0
    end

    def call
      ActorProfile
        .where(classification: "exchange_like")
        .find_each do |profile|
          sync_cluster(profile.cluster_id)
        end

      {
        ok: true,
        clusters: @clusters,
        inserted: @inserted,
        source: SOURCE
      }
    end

    private

    def sync_cluster(cluster_id)
      @clusters += 1

      puts "[sync] cluster=#{cluster_id} start"

      Address
        .where(cluster_id: cluster_id)
        .where.not(address: [nil, ""])
        .find_in_batches(batch_size: BATCH_SIZE)
        .with_index do |batch, index|
          rows = batch.map do |addr|
            {
              address: addr.address,
              cluster_id: cluster_id,
              source: SOURCE,
              created_at: Time.current,
              updated_at: Time.current
            }
          end

          next if rows.empty?

          before = ExchangeCoreAddress.count

          ExchangeCoreAddress.insert_all(
            rows,
            unique_by: :index_exchange_core_addresses_on_address
          )

          after = ExchangeCoreAddress.count
          added = after - before
          @inserted += added

          puts "[sync] cluster=#{cluster_id} batch=#{index + 1} rows=#{rows.size} added=#{added} total_inserted=#{@inserted}"
        end

      puts "[sync] cluster=#{cluster_id} done"
    end
  end
end
