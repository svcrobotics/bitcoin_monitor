# frozen_string_literal: true

module ExchangeLike
  class ObservedSeenBuilder
    Stats = Struct.new(
      :scanned_txs,
      :scanned_vouts,
      :seen_rows,
      keyword_init: true
    ) do
      def initialize(**attrs)
        super
        self.scanned_txs ||= 0
        self.scanned_vouts ||= 0
        self.seen_rows ||= 0
      end

      def to_h
        {
          scanned_txs: scanned_txs,
          scanned_vouts: scanned_vouts,
          seen_rows: seen_rows
        }
      end
    end

    def initialize(model_columns:, tz:, max_single_utxo_btc:, suspicious_btc:)
      @model_columns = model_columns
      @tz = tz
      @max_single_utxo_btc = max_single_utxo_btc
      @suspicious_btc = suspicious_btc
    end

    def call(block:, exchange_set:)
      stats = Stats.new
      rows = []

      blockhash = block["hash"].to_s
      blockheight = block["height"].to_i
      block_time_i = block["time"].to_i

      Array(block["tx"]).each do |tx|
        txid = tx["txid"].to_s
        next if txid.empty?

        stats.scanned_txs += 1

        Array(tx["vout"]).each do |vout|
          stats.scanned_vouts += 1

          row = build_seen_row(
            txid: txid,
            vout: vout,
            exchange_set: exchange_set,
            block_time_i: block_time_i,
            blockhash: blockhash,
            blockheight: blockheight
          )

          next if row.nil?

          rows << row
          stats.seen_rows += 1
        end
      end

      { rows: rows, stats: stats.to_h }
    end

    private

    def build_seen_row(txid:, vout:, exchange_set:, block_time_i:, blockhash:, blockheight:)
      n = vout["n"]
      return nil if n.nil?

      spk = vout["scriptPubKey"] || {}
      addr = extract_address(spk)
      return nil if addr.blank?
      return nil unless exchange_set.include?(addr)

      btc = normalize_value_btc(
        vout["value"],
        txid: txid,
        vout: n,
        addr: addr,
        height: blockheight
      )
      return nil if btc.nil? || btc <= 0

      seen_row(txid, n, btc, addr, block_time_i, blockhash, blockheight)
    end

    def seen_row(txid, vout, value_btc, address, block_time_i, blockhash, blockheight)
      now = Time.current
      day = day_for(block_time_i)

      h = {
        txid: txid,
        vout: vout.to_i,
        value_btc: value_btc,
        address: address,
        seen_day: day,
        created_at: now,
        updated_at: now
      }

      h[:seen_at]          = time_for(block_time_i) if @model_columns.include?("seen_at")
      h[:seen_blockhash]   = blockhash              if @model_columns.include?("seen_blockhash")
      h[:seen_blockheight] = blockheight            if @model_columns.include?("seen_blockheight")

      filter_to_columns!(h, extra_allowed: %w[txid vout created_at updated_at])
    end

    def filter_to_columns!(hash, extra_allowed:)
      allowed = @model_columns + extra_allowed.to_set
      hash.select { |k, _| allowed.include?(k.to_s) }
    end

    def extract_address(script_pubkey)
      a = script_pubkey["address"].presence
      return a if a.present?

      arr = script_pubkey["addresses"]
      return arr.first.to_s if arr.is_a?(Array) && arr.first.present?

      nil
    end

    def normalize_value_btc(val, txid:, vout:, addr:, height:)
      return nil if val.nil?

      raw = val

      btc =
        if raw.is_a?(Integer)
          BigDecimal(raw.to_s) / 100_000_000
        elsif raw.is_a?(String)
          s = raw.strip
          return nil if s.empty?
          s.match?(/\A\d+\z/) ? (BigDecimal(s) / 100_000_000) : BigDecimal(s)
        else
          raw.to_d
        end

      if btc > @suspicious_btc
        raw_bd = (BigDecimal(raw.to_s) rescue nil)
        if raw_bd
          cand_sats = raw_bd / 100_000_000
          btc = cand_sats if cand_sats > 0 && cand_sats < btc

          cand_bug = raw_bd / 100_000
          btc = cand_bug if cand_bug > 0 && cand_bug < btc
        end
      end

      if btc > @max_single_utxo_btc
        puts "[exchange_observed_scan] WARN suspicious vout value; "\
             "skipping height=#{height} txid=#{txid} vout=#{vout} addr=#{addr} "\
             "raw=#{raw.inspect} normalized_btc=#{btc.to_s('F')}"
        return nil
      end

      btc
    rescue => e
      puts "[exchange_observed_scan] WARN value normalize error; "\
           "skipping height=#{height} txid=#{txid} vout=#{vout} addr=#{addr} "\
           "raw=#{val.inspect} err=#{e.class}:#{e.message}"
      nil
    end

    def day_for(block_time_i)
      Time.at(block_time_i).in_time_zone(@tz).to_date
    end

    def time_for(block_time_i)
      Time.at(block_time_i).in_time_zone(@tz)
    end
  end
end