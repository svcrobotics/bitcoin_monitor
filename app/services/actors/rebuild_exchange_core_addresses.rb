# frozen_string_literal: true

module Actors
  class RebuildExchangeCoreAddresses
    SOURCE = "actor_profile_exchange_like"

    def self.call
      cluster_ids =
        ActorLabel
          .where(source: "actor_profile", label: "exchange_like")
          .pluck(:cluster_id)
          .compact
          .uniq

      ExchangeCoreAddress.delete_all

      rows =
        Address
          .where(cluster_id: cluster_ids)
          .pluck(:address, :cluster_id)
          .map do |address, cluster_id|
            {
              address: address,
              cluster_id: cluster_id,
              source: SOURCE,
              created_at: Time.current,
              updated_at: Time.current
            }
          end

      rows.each_slice(10_000) do |slice|
        ExchangeCoreAddress.insert_all(slice, unique_by: :index_exchange_core_addresses_on_address)
      end

      {
        ok: true,
        source: SOURCE,
        clusters: cluster_ids.size,
        addresses: rows.size
      }
    end
  end
end
