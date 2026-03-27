# frozen_string_literal: true

# app/services/exchange_observed_scanner.rb
#
# ExchangeObservedScanner
# ======================
#
# Objectif
# --------
# Observer l'activité on-chain des adresses déjà présentes dans le set
# `exchange_addresses`.
#
# Modes de fonctionnement
# -----------------------
# 1. Mode incrémental (par défaut)
#    - reprend depuis ScannerCursor
#    - traite uniquement les nouveaux blocs
#    - met à jour le curseur à la fin
#
# 2. Mode manuel / backfill
#    - si last_n_blocks est fourni
#    - ou si days_back est fourni explicitement
#    - ne met pas à jour le curseur
#
# Important
# ---------
# Le scanner travaille sur un set opérationnel :
#
#   ExchangeAddress.operational
#
require "set"

class ExchangeObservedScanner
  class Error < StandardError; end

  CURSOR_NAME = "exchange_observed_scan"

  MIN_OCC_FALLBACK  = (Integer(ENV.fetch("EXCHANGE_ADDR_MIN_OCC", "3")) rescue 3)
  MIN_CONF_FALLBACK = (Integer(ENV.fetch("EXCHANGE_ADDR_MIN_CONFIDENCE", "20")) rescue 20)

  BATCH_UPSERT       = (Integer(ENV.fetch("EXCHANGE_OBS_UPSERT_BATCH", "2000")) rescue 2000)
  DAYS_BACK_DEFAULT  = (Integer(ENV.fetch("EXCHANGE_OBSERVED_DAYS_BACK", "3")) rescue 3)
  INITIAL_BLOCKS_BACK = (Integer(ENV.fetch("EXCHANGE_OBS_INITIAL_BLOCKS_BACK", "50")) rescue 50)

  TZ = ENV.fetch("APP_TZ", "Europe/Paris")

  MAX_SINGLE_UTXO_BTC = (ENV.fetch("EXCHANGE_OBS_MAX_UTXO_BTC", "5000").to_d rescue 5000.to_d)
  SUSPICIOUS_BTC      = (ENV.fetch("EXCHANGE_OBS_SUSPICIOUS_BTC", "1000").to_d rescue 1000.to_d)

  def self.call(days_back: nil, last_n_blocks: nil, rpc: nil)
    new(days_back: days_back, last_n_blocks: last_n_blocks, rpc: rpc).call
  end

  def initialize(days_back:, last_n_blocks:, rpc:)
    @days_back_explicit = !days_back.nil?
    @days_back          = days_back.nil? ? DAYS_BACK_DEFAULT : days_back.to_i
    @last_n_blocks      = last_n_blocks.present? ? last_n_blocks.to_i : nil
    @rpc                = rpc || BitcoinRpc.new(wallet: nil)
  end

  def call
    exchange_set = load_exchange_like_addresses_set
    return empty_result("no operational exchange addresses") if exchange_set.empty?

    best_height = @rpc.getblockcount.to_i
    range       = compute_scan_range(best_height)

    return empty_result("nothing to scan", best_height: best_height, mode: range[:mode]) if range[:start_height] > range[:end_height]

    seen_rows  = []
    spent_rows = []
    scanned_blocks = 0

    puts "[exchange_observed_scan] start "\
         "mode=#{range[:mode]} start_height=#{range[:start_height]} end_height=#{range[:end_height]} "\
         "exchange_set_size=#{exchange_set.size}"

    (range[:start_height]..range[:end_height]).each do |height|
      blockhash = @rpc.getblockhash(height)
      block     = @rpc.getblock(blockhash, 2)
      block_time_i = block["time"].to_i

      scanned_blocks += 1
      log_progress(scanned_blocks, height, seen_rows.size, spent_rows.size, exchange_set.size)

      Array(block["tx"]).each do |tx|
        txid = tx["txid"].to_s
        next if txid.empty?

        Array(tx["vin"]).each do |vin|
          prev_txid = vin["txid"].to_s
          prev_vout = vin["vout"]
          next if prev_txid.empty? || prev_vout.nil?

          spent_rows << spent_row(prev_txid, prev_vout, txid, block_time_i, blockhash, height)
          flush_spent!(spent_rows) if spent_rows.size >= BATCH_UPSERT
        end

        Array(tx["vout"]).each do |vout|
          n = vout["n"]
          next if n.nil?

          spk  = vout["scriptPubKey"] || {}
          addr = extract_address(spk)
          next if addr.blank?
          next unless exchange_set.include?(addr)

          btc = normalize_value_btc(vout["value"], txid: txid, vout: n, addr: addr, height: height)
          next if btc.nil? || btc <= 0

          seen_rows << seen_row(txid, n, btc, addr, block_time_i, blockhash, height)
          flush_seen!(seen_rows) if seen_rows.size >= BATCH_UPSERT
        end
      end
    end

    flush_seen!(seen_rows)
    flush_spent!(spent_rows)

    update_cursor!(range[:end_height]) if range[:mode] == :incremental

    {
      ok: true,
      mode: range[:mode],
      scanned_blocks: scanned_blocks,
      start_height: range[:start_height],
      end_height: range[:end_height],
      best_height: best_height,
      exchange_set_size: exchange_set.size
    }
  end

  private

  def empty_result(note, best_height: nil, mode: nil)
    {
      ok: true,
      note: note,
      best_height: best_height,
      mode: mode
    }
  end

  # ---------------------------------------------------------------------------
  # Scan range
  # ---------------------------------------------------------------------------

  def compute_scan_range(best_height)
    if manual_mode?
      if @last_n_blocks.present? && @last_n_blocks > 0
        start_height = [0, best_height - @last_n_blocks + 1].max
        return { mode: :manual_last_n_blocks, start_height: start_height, end_height: best_height }
      end

      start_time = @days_back.days.ago.to_time.to_i
      start_height = find_first_height_for_time(start_time, best_height)
      return { mode: :manual_days_back, start_height: start_height, end_height: best_height }
    end

    cursor = scanner_cursor
    if cursor.last_blockheight.present?
      start_height = cursor.last_blockheight.to_i + 1
      { mode: :incremental, start_height: start_height, end_height: best_height }
    else
      start_height = [0, best_height - INITIAL_BLOCKS_BACK + 1].max
      { mode: :incremental, start_height: start_height, end_height: best_height }
    end
  end

  def manual_mode?
    @last_n_blocks.present? || @days_back_explicit
  end

  # Recherche simple du premier blockheight >= start_time
  # V1 : recherche linéaire vers l’arrière depuis best_height.
  def find_first_height_for_time(start_time, best_height)
    height = best_height
    while height >= 0
      blockhash = @rpc.getblockhash(height)
      block = @rpc.getblock(blockhash, 1)
      return height if block["time"].to_i < start_time

      height -= 1
    end
    0
  rescue BitcoinRpc::Error
    0
  end

  # ---------------------------------------------------------------------------
  # Cursor
  # ---------------------------------------------------------------------------

  def scanner_cursor
    @scanner_cursor ||= ScannerCursor.find_or_create_by!(name: CURSOR_NAME)
  end

  def update_cursor!(height)
    blockhash = @rpc.getblockhash(height)

    scanner_cursor.update!(
      last_blockheight: height,
      last_blockhash: blockhash
    )
  end

  # ---------------------------------------------------------------------------
  # Logging
  # ---------------------------------------------------------------------------

  def log_progress(scanned_blocks, height, seen_buf, spent_buf, exchange_set_size)
    log_every =
      if @last_n_blocks.present? && @last_n_blocks > 0
        [10, (@last_n_blocks / 5.0).ceil].max
      else
        25
      end

    return unless (scanned_blocks % log_every).zero?

    puts "[exchange_observed_scan] progress "\
         "blocks=#{scanned_blocks} height=#{height} "\
         "exchange_set_size=#{exchange_set_size} "\
         "seen_buffer=#{seen_buf} spent_buffer=#{spent_buf}"
  end

  # ---------------------------------------------------------------------------
  # Model metadata
  # ---------------------------------------------------------------------------

  def model_columns
    @model_columns ||= ExchangeObservedUtxo.column_names.to_set
  end

  def day_for(block_time_i)
    Time.at(block_time_i).in_time_zone(TZ).to_date
  end

  def time_for(block_time_i)
    Time.at(block_time_i).in_time_zone(TZ)
  end

  # ---------------------------------------------------------------------------
  # Row builders
  # ---------------------------------------------------------------------------

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

    h[:seen_at]          = time_for(block_time_i) if model_columns.include?("seen_at")
    h[:seen_blockhash]   = blockhash              if model_columns.include?("seen_blockhash")
    h[:seen_blockheight] = blockheight            if model_columns.include?("seen_blockheight")

    filter_to_columns!(h, extra_allowed: %w[txid vout created_at updated_at])
  end

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

    h[:spent_at]          = time_for(block_time_i) if model_columns.include?("spent_at")
    h[:spent_blockhash]   = blockhash              if model_columns.include?("spent_blockhash")
    h[:spent_blockheight] = blockheight            if model_columns.include?("spent_blockheight")

    filter_to_columns!(h, extra_allowed: %w[txid vout updated_at])
  end

  def filter_to_columns!(hash, extra_allowed:)
    allowed = model_columns + extra_allowed.to_set
    hash.select { |k, _| allowed.include?(k.to_s) }
  end

  # ---------------------------------------------------------------------------
  # Flushers
  # ---------------------------------------------------------------------------

  def flush_seen!(rows)
    return if rows.empty?

    ExchangeObservedUtxo.upsert_all(
      rows,
      unique_by: :index_exchange_observed_utxos_on_txid_and_vout
    )

    rows.clear
  end

  def flush_spent!(rows)
    return if rows.empty?

    now = Time.current

    keys = rows.map { |r| [r[:txid].to_s, r[:vout].to_i] }.uniq

    existing =
      ExchangeObservedUtxo
        .where(
          txid: keys.map(&:first),
          vout: keys.map(&:last)
        )
        .index_by { |u| [u.txid.to_s, u.vout.to_i] }

    upsert_rows = []

    rows.each do |r|
      key = [r[:txid].to_s, r[:vout].to_i]
      current = existing[key]
      next if current.blank?
      next if current.spent_by_txid.present?

      upsert_rows << {
        txid: current.txid,
        vout: current.vout,
        value_btc: current.value_btc,
        address: current.address,
        seen_day: current.seen_day,
        created_at: current.created_at || now,
        updated_at: now,
        spent_by_txid: r[:spent_by_txid],
        spent_day: r[:spent_day],
        spent_at: (model_columns.include?("spent_at") ? r[:spent_at] : current.try(:spent_at)),
        spent_blockhash: (model_columns.include?("spent_blockhash") ? r[:spent_blockhash] : current.try(:spent_blockhash)),
        spent_blockheight: (model_columns.include?("spent_blockheight") ? r[:spent_blockheight] : current.try(:spent_blockheight)),
        seen_at: (model_columns.include?("seen_at") ? current.try(:seen_at) : nil),
        seen_blockhash: (model_columns.include?("seen_blockhash") ? current.try(:seen_blockhash) : nil),
        seen_blockheight: (model_columns.include?("seen_blockheight") ? current.try(:seen_blockheight) : nil)
      }.compact
    end

    if upsert_rows.any?
      ExchangeObservedUtxo.upsert_all(
        upsert_rows,
        unique_by: :index_exchange_observed_utxos_on_txid_and_vout
      )
    end

    rows.clear
  end

  # ---------------------------------------------------------------------------
  # Exchange set
  # ---------------------------------------------------------------------------

  def load_exchange_like_addresses_set
    rel =
      if ExchangeAddress.respond_to?(:scannable)
        ExchangeAddress.scannable
      elsif ExchangeAddress.respond_to?(:operational)
        ExchangeAddress.operational
      else
        ExchangeAddress.where.not(address: [nil, ""])
      end

    rel.where.not(address: [nil, ""]).pluck(:address).to_set
  end

  def extract_address(script_pubkey)
    a = script_pubkey["address"].presence
    return a if a.present?

    arr = script_pubkey["addresses"]
    return arr.first.to_s if arr.is_a?(Array) && arr.first.present?

    nil
  end

  # ---------------------------------------------------------------------------
  # Value normalization
  # ---------------------------------------------------------------------------

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

    if btc > SUSPICIOUS_BTC
      raw_bd = (BigDecimal(raw.to_s) rescue nil)
      if raw_bd
        cand_sats = raw_bd / 100_000_000
        btc = cand_sats if cand_sats > 0 && cand_sats < btc

        cand_bug = raw_bd / 100_000
        btc = cand_bug if cand_bug > 0 && cand_bug < btc
      end
    end

    if btc > MAX_SINGLE_UTXO_BTC
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
end