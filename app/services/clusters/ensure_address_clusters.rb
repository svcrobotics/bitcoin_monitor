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
      return result if @addresses.empty?

      Address
        .where(address: @addresses, cluster_id: nil)
        .find_each do |addr|
          ApplicationRecord.transaction do
            addr.lock!
            next if addr.cluster_id.present?

            cluster = Cluster.create!
            addr.update!(cluster: cluster)
            cluster.recalculate_stats!

            admission = ActorProfiles::Admission.register_latest(
              cluster_ids: [cluster.id], reason: "missing_profile"
            )

            @updated += 1
            @marked += admission[:created]
          end
        end

      result
    end

    private

    def result
      {
        ok: true,
        updated: @updated,
        clusters: @updated,
        marked: @marked
      }
    end
  end
end
