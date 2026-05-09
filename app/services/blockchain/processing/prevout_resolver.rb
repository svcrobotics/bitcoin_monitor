# frozen_string_literal: true

module Blockchain
  module Processing
    class PrevoutResolver
      def initialize(rpc: BitcoinRpc.new, logger: Rails.logger, rpc_fallback: false, cache: nil)
        @rpc = rpc
        @logger = logger
        @rpc_fallback = rpc_fallback
        @cache = cache
      end

      def call(input)
        return { coinbase: true } if input[:coinbase] || input["coinbase"]

        txid = input[:txid] || input["txid"]
        vout_index = input[:vout] || input["vout"]

        return nil unless txid.present? && vout_index.is_a?(Integer)

        cached = find_cached(txid, vout_index)
        return cached if cached

        output = find_output(txid, vout_index)
        return normalize_from_db(output) if output

        return nil unless @rpc_fallback

        normalize_from_rpc(txid, vout_index)
      rescue StandardError => e
        @logger.warn(
          "[prevout_resolver] failed txid=#{txid} vout=#{vout_index} #{e.class}: #{e.message}"
        )
        nil
      end

      private

      def find_cached(txid, vout_index)
        return nil unless @cache

        @cache[[txid, vout_index]]
      end

      def find_output(txid, vout_index)
        TxOutput.find_by(txid: txid, vout: vout_index)
      end

      def normalize_from_db(output)
        {
          txid: output.txid,
          vout: output.vout,
          address: output.address,
          amount: output.amount_btc
        }
      end

      def normalize_from_rpc(txid, vout_index)
        tx = @rpc.getrawtransaction(txid, true)
        utxo = tx["vout"]&.[](vout_index)
        return nil unless utxo

        {
          txid: txid,
          vout: vout_index,
          address: extract_address(utxo),
          amount: utxo["value"]
        }
      end

      def extract_address(vout)
        spk = vout["scriptPubKey"] || {}

        return spk["address"] if spk["address"]
        return spk["addresses"]&.first if spk["addresses"]

        nil
      end
    end
  end
end