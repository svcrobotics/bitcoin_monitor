# frozen_string_literal: true

require "bigdecimal"

module ExchangeLike
  class OutputCandidateExtractor
    Candidate = Struct.new(
      :address,
      :txid,
      :value_btc,
      :seen_at,
      keyword_init: true
    )

    Stats = Struct.new(
      :scanned_txs,
      :scanned_vouts,
      :learned_outputs,
      :skipped_coinbase_txs,
      :skipped_nulldata_outputs,
      :skipped_small_outputs,
      :skipped_large_outputs,
      :skipped_blank_addresses,
      keyword_init: true
    ) do
      def initialize(**attrs)
        super
        self.scanned_txs ||= 0
        self.scanned_vouts ||= 0
        self.learned_outputs ||= 0
        self.skipped_coinbase_txs ||= 0
        self.skipped_nulldata_outputs ||= 0
        self.skipped_small_outputs ||= 0
        self.skipped_large_outputs ||= 0
        self.skipped_blank_addresses ||= 0
      end

      def to_h
        {
          scanned_txs: scanned_txs,
          scanned_vouts: scanned_vouts,
          learned_outputs: learned_outputs,
          skipped_coinbase_txs: skipped_coinbase_txs,
          skipped_nulldata_outputs: skipped_nulldata_outputs,
          skipped_small_outputs: skipped_small_outputs,
          skipped_large_outputs: skipped_large_outputs,
          skipped_blank_addresses: skipped_blank_addresses
        }
      end
    end

    def initialize(rpc:, min_output_btc:, max_output_btc:)
      @rpc = rpc
      @min_output_btc = min_output_btc
      @max_output_btc = max_output_btc
      @desc_cache = {}
    end

    def call(block)
      stats = Stats.new
      candidates = []

      seen_at = block_time_from_block(block)

      Array(block["tx"]).each do |tx|
        extract_from_transaction(tx, seen_at:, candidates:, stats:)
      end

      { candidates: candidates, stats: stats.to_h }
    end

    private

    def extract_from_transaction(tx, seen_at:, candidates:, stats:)
      return if tx.blank?

      stats.scanned_txs += 1

      txid = tx["txid"].to_s
      return if txid.blank?

      if coinbase_transaction?(tx)
        stats.skipped_coinbase_txs += 1
        return
      end

      Array(tx["vout"]).each do |vout|
        stats.scanned_vouts += 1
        candidate = extract_candidate_from_vout(vout, txid:, seen_at:, stats:)
        candidates << candidate if candidate
      end
    end

    def extract_candidate_from_vout(vout, txid:, seen_at:, stats:)
      return nil if vout.blank?

      value = decimal_value(vout["value"])
      return nil if value <= 0

      if value < @min_output_btc
        stats.skipped_small_outputs += 1
        return nil
      end

      if value > @max_output_btc
        stats.skipped_large_outputs += 1
        return nil
      end

      spk = vout["scriptPubKey"] || {}

      if spk["type"].to_s == "nulldata"
        stats.skipped_nulldata_outputs += 1
        return nil
      end

      address = scriptpubkey_address(spk)
      if address.blank?
        stats.skipped_blank_addresses += 1
        return nil
      end

      stats.learned_outputs += 1

      Candidate.new(
        address: address,
        txid: txid,
        value_btc: value,
        seen_at: seen_at
      )
    end

    def coinbase_transaction?(tx)
      Array(tx["vin"]).any? { |vin| vin["coinbase"].present? }
    end

    def block_time_from_block(block)
      t = block["time"] || block["mediantime"]
      Time.at(t.to_i)
    rescue
      Time.current
    end

    def decimal_value(value)
      BigDecimal(value.to_s)
    rescue
      0.to_d
    end

    def scriptpubkey_address(spk)
      addr = spk["address"] || Array(spk["addresses"]).first
      return addr if addr.present?

      desc = spk["desc"].to_s
      return nil if desc.blank?

      @desc_cache[desc] ||= Array(@rpc.deriveaddresses(desc)).first
    rescue BitcoinRpc::Error
      nil
    rescue StandardError
      nil
    end
  end
end
