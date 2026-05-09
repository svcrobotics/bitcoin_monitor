# frozen_string_literal: true

module Blockchain
  module Processing
    class BulkPrevoutResolver
      DEFAULT_BATCH_SIZE = 2_000

      def initialize(batch_size: DEFAULT_BATCH_SIZE, logger: Rails.logger)
        @batch_size = batch_size
        @logger = logger
      end

      def call(transactions)
        keys = extract_keys(transactions)
        return {} if keys.empty?

        result = {}

        keys.each_slice(@batch_size) do |slice|
          txids = slice.map(&:first).uniq

          TxOutput
            .where(txid: txids)
            .select(:id, :txid, :vout, :address, :amount_btc)
            .find_each do |output|
              key = [output.txid, output.vout.to_i]
              next unless slice.include?(key)

              result[key] = {
                txid: output.txid,
                vout: output.vout,
                address: output.address,
                amount: output.amount_btc
              }
            end
        end

        @logger.info(
          "[bulk_prevout_resolver] keys=#{keys.size} resolved=#{result.size}"
        )

        result
      end

      private

      def extract_keys(transactions)
        transactions.flat_map do |tx|
          inputs = tx[:inputs] || tx["vin"] || []

          inputs.filter_map do |input|
            next if input[:coinbase] || input["coinbase"]

            txid = input[:txid] || input["txid"]
            vout = input[:vout] || input["vout"]

            next if txid.blank?
            next unless vout.is_a?(Integer)

            [txid, vout]
          end
        end.uniq
      end
    end
  end
end