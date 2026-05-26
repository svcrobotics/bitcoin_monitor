# app/services/actor_labels/import_etf_like_from_addresses.rb
require "yaml"

module ActorLabels
  class ImportEtfLikeFromAddresses
    DEFAULT_PATH = Rails.root.join("config/etf_addresses.yml")

    def self.call(path: DEFAULT_PATH)
      new(path).call
    end

    def initialize(path)
      @path = path
    end

    def call
      entries = YAML.load_file(@path) || []

      stats = {
        entries: entries.size,
        addresses: 0,
        found: 0,
        missing: 0,
        labels_created_or_updated: 0
      }

      entries.each do |entry|
        Array(entry["addresses"]).each do |address|
          stats[:addresses] += 1

          cluster_id = find_cluster_id(address)

          if cluster_id.blank?
            stats[:missing] += 1
            Rails.logger.warn("[etf_like_import] address_not_found address=#{address}")
            next
          end

          stats[:found] += 1

          MarkEtfLike.call(
            cluster_id: cluster_id,
            name: entry["name"],
            confidence: 95,
            source: entry["source"] || "manual_verified",
            metadata: {
              issuer: entry["issuer"],
              product: entry["product"],
              custody: entry["custody"],
              matched_address: address
            }.compact
          )

          stats[:labels_created_or_updated] += 1
        end
      end

      stats
    end

    private

    def find_cluster_id(address)
      # Cas 1 : si tx_outputs porte directement cluster_id
      if TxOutput.column_names.include?("cluster_id")
        cluster_id = TxOutput.where(address: address).where.not(cluster_id: nil).limit(1).pick(:cluster_id)
        return cluster_id if cluster_id.present?
      end

      # Cas 2 : si tu as une table cluster_addresses
      if defined?(ClusterAddress)
        cluster_id = ClusterAddress.where(address: address).limit(1).pick(:cluster_id)
        return cluster_id if cluster_id.present?
      end

      nil
    end
  end
end
