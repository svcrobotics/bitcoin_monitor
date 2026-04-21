# frozen_string_literal: true

module ExchangeLike
  class ObservedSpentMarker
    Stats = Struct.new(
      :spent_rows,
      keyword_init: true
    ) do
      def initialize(**attrs)
        super
        self.spent_rows ||= 0
      end

      def to_h
        { spent_rows: spent_rows }
      end
    end

    def initialize(model_columns:, tz:)
      @model_columns = model_columns
      @tz = tz
    end

    def call(block:)
      stats = Stats.new
      rows = []

      blockhash = block["hash"].to_s
      blockheight = block["height"].to_i
      block_time_i = block["time"].to_i

      Array(block["tx"]).each do |tx|
        txid = tx["txid"].to_s
        next if txid.empty?

        Array(tx["vin"]).each do |vin|
          prev_txid = vin["txid"].to_s
          prev_vout = vin["vout"]
          next if prev_txid.empty? || prev_vout.nil?

          rows << spent_row(prev_txid, prev_vout, txid, block_time_i, blockhash, blockheight)
          stats.spent_rows += 1
        end
      end

      { rows: rows, stats: stats.to_h }
    end

    private

    def spent_row(prev_txid, prev_vout, spending_txid, block_time_i, blockhash, blockheight)
      now = Time.current
      day = day_for(block_time_i)

      h = {
        txid: prev_txid,
        vout: prev_vout.to_i,
        spent_by_txid: spending_txid,
        spent_day: day,
        updated_at: now
      }

      h[:spent_at]          = time_for(block_time_i) if @model_columns.include?("spent_at")
      h[:spent_blockhash]   = blockhash              if @model_columns.include?("spent_blockhash")
      h[:spent_blockheight] = blockheight            if @model_columns.include?("spent_blockheight")

      filter_to_columns!(h, extra_allowed: %w[txid vout updated_at])
    end

    def filter_to_columns!(hash, extra_allowed:)
      allowed = @model_columns + extra_allowed.to_set
      hash.select { |k, _| allowed.include?(k.to_s) }
    end

    def day_for(block_time_i)
      Time.at(block_time_i).in_time_zone(@tz).to_date
    end

    def time_for(block_time_i)
      Time.at(block_time_i).in_time_zone(@tz)
    end
  end
end