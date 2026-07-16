# frozen_string_literal: true

module Clusters
  class EnsureAddressClusters
    def self.call(addresses:)
      new(addresses: addresses).call
    end

    def initialize(addresses:)
      @addresses = Array(addresses).compact_blank.uniq
      @updated = 0
      @marked = 0
    end

    def call
      return { ok: true, updated: 0, marked: 0 } if @addresses.empty?

      Address
        .where(address: @addresses, cluster_id: nil)
        .find_each do |addr|
          cluster = Cluster.create!
          addr.update!(cluster_id: cluster.id, updated_at: Time.current)

          admission = ActorProfiles::Admission.register_latest(
            cluster_ids: [cluster.id], reason: "missing_profile"
          )

          @updated += 1
          @marked += admission[:created]
        end

      { ok: true, updated: @updated, marked: @marked }
    end
  end
end
