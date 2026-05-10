# frozen_string_literal: true

module Blockchain
  module Utxo
    class SpentMarker
      def initialize(logger: Rails.logger)
        @logger = logger
      end

      def call(payload)
        txid = payload[:previous_txid]
        vout = payload[:previous_vout]

        return unless txid && vout

        TxOutput
          .where(txid: txid, vout: vout)
          .update_all(
            spent: true,
            spent_txid: payload[:txid],
            spent_block_height: payload[:block_height],
            updated_at: Time.current
          )
      rescue => e
        @logger.error(
          "[spent_marker] error txid=#{txid} vout=#{vout} #{e.class}: #{e.message}"
        )
      end
    end
  end
end