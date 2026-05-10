# frozen_string_literal: true

module Blockchain
  module Processing
    class TxNormalizer
      def self.call(tx)
        new(tx).call
      end

      def initialize(tx)
        @tx = tx
      end

      def call
        {
          txid: txid,
          inputs: normalize_inputs,
          outputs: normalize_outputs
        }
      end

      private

      attr_reader :tx

      # -----------------------------
      # CORE
      # -----------------------------
      def txid
        tx["txid"]
      end

      # -----------------------------
      # INPUTS
      # -----------------------------
      def normalize_inputs
        Array(tx["vin"]).map do |vin|
          if vin["coinbase"]
            { coinbase: true }
          else
            {
              txid: vin["txid"],
              vout: vin["vout"],
              coinbase: false
            }
          end
        end
      end

      # -----------------------------
      # OUTPUTS
      # -----------------------------
      def normalize_outputs
        Array(tx["vout"]).each_with_index.map do |vout, index|
          {
            vout: index,
            value: vout["value"],
            address: extract_address(vout)
          }
        end
      end

      # -----------------------------
      # ADDRESS EXTRACTION
      # -----------------------------
      def extract_address(vout)
        spk = vout["scriptPubKey"] || {}

        return spk["address"] if spk["address"]
        return spk["addresses"]&.first if spk["addresses"]

        nil
      end
    end
  end
end