# app/services/clusters/input_extractor.rb

module Clusters
  class InputExtractor
    def self.call(tx)
      new(tx).call
    end

    def initialize(tx)
      @tx = tx
    end

    def call
      return [] if coinbase_tx?

      rows = extract_rows

      grouped = rows.group_by { |r| r[:address] }

      grouped.map do |address, inputs|
        {
          address: address,
          total_inputs: inputs.size,
          total_value_sats: inputs.sum { |i| i[:value_sats] }
        }
      end
    end

    private

    attr_reader :tx

    def coinbase_tx?
      Array(tx["vin"]).any? { |vin| vin["coinbase"].present? }
    end

    def extract_rows
      Array(tx["vin"]).filter_map do |vin|
        prevout = vin["prevout"]
        next unless prevout

        script_pub_key = prevout["scriptPubKey"] || {}

        address =
          script_pub_key["address"] ||
          Array(script_pub_key["addresses"]).first

        next if address.blank?

        value_sats =
          ((prevout["value"].to_d) * 100_000_000).to_i

        {
          address: address,
          value_sats: value_sats
        }
      end
    end
  end
end