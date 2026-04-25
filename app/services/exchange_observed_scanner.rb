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

  MIN_OCC_FALLBACK   = (Integer(ENV.fetch("EXCHANGE_ADDR_MIN_OCC", "3")) rescue 3)
  MIN_CONF_FALLBACK  = (Integer(ENV.fetch("EXCHANGE_ADDR_MIN_CONFIDENCE", "20")) rescue 20)

  BATCH_UPSERT        = (Integer(ENV.fetch("EXCHANGE_OBS_UPSERT_BATCH", "2000")) rescue 2000)
  DAYS_BACK_DEFAULT   = (Integer(ENV.fetch("EXCHANGE_OBSERVED_DAYS_BACK", "3")) rescue 3)
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

    @scannable_address_set = ExchangeLike::ScannableAddressSet.new
    @seen_builder = ExchangeLike::ObservedSeenBuilder.new(
      model_columns: model_columns,
      tz: TZ,
      max_single_utxo_btc: MAX_SINGLE_UTXO_BTC,
      suspicious_btc: SUSPICIOUS_BTC
    )
    @spent_marker = ExchangeLike::ObservedSpentMarker.new(
      model_columns: model_columns,
      tz: TZ
    )

    reset_runtime_state!
  end

  def call
    scannable = @scannable_address_set.call
    return empty_result("no operational exchange addresses") if scannable.addresses.empty?

    best_height = @rpc.getblockcount.to_i
    range = compute_scan_range(best_height)

    if range[:start_height] > range[:end_height]
      return empty_result("nothing to scan", best_height: best_height, mode: range[:mode])
    end

    puts "[exchange_observed_scan] start "\
         "mode=#{range[:mode]} start_height=#{range[:start_height]} end_height=#{range[:end_height]} "\
         "exchange_set_size=#{scannable.count}"

    scan_range(range, scannable.addresses)

    flush_seen!
    flush_spent!

    update_cursor!(range[:end_height]) if range[:mode] == :incremental

    {
      ok: true,
      mode: range[:mode],
      scanned_blocks: @run_stats[:scanned_blocks],
      scanned_txs: @run_stats[:scanned_txs],
      scanned_vouts: @run_stats[:scanned_vouts],
      seen_rows: @run_stats[:seen_rows],
      spent_rows: @run_stats[:spent_rows],
      start_height: range[:start_height],
      end_height: range[:end_height],
      best_height: best_height,
      exchange_set_size: scannable.count
    }
  end

  private

  def reset_runtime_state!
    @seen_rows_buffer = []
    @spent_rows_buffer = []

    @run_stats = {
      scanned_blocks: 0,
      scanned_txs: 0,
      scanned_vouts: 0,
      seen_rows: 0,
      spent_rows: 0,
      rpc_errors: 0
    }
  end

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
  # Main scan loop
  # ---------------------------------------------------------------------------

  def scan_range(range, exchange_set)
    start_height = range[:start_height].to_i
    end_height   = range[:end_height].to_i
    total_blocks = end_height - start_height + 1

    (start_height..end_height).each_with_index do |height, index|
      scan_height(height, exchange_set)

      update_job_progress!(
        current: index + 1,
        total: total_blocks,
        height: height
      )
    end
  end

  def scan_height(height, exchange_set)
    blockhash = @rpc.getblockhash(height)
    block = @rpc.getblock(blockhash, 2)

    @run_stats[:scanned_blocks] += 1
    log_progress(
      @run_stats[:scanned_blocks],
      height,
      @seen_rows_buffer.size,
      @spent_rows_buffer.size,
      exchange_set.size
    )

    process_block(block, exchange_set)
  rescue BitcoinRpc::Error => e
    @run_stats[:rpc_errors] += 1
    puts "[exchange_observed_scan] skip height=#{height} rpc_error=#{e.message}"
  end

  def process_block(block, exchange_set)
    seen_result = @seen_builder.call(block: block, exchange_set: exchange_set)
    spent_result = @spent_marker.call(block: block)

    merge_seen_stats!(seen_result[:stats])
    merge_spent_stats!(spent_result[:stats])

    @seen_rows_buffer.concat(seen_result[:rows])
    @spent_rows_buffer.concat(spent_result[:rows])

    flush_seen! if @seen_rows_buffer.size >= BATCH_UPSERT
    flush_spent! if @spent_rows_buffer.size >= BATCH_UPSERT
  end

  def merge_seen_stats!(stats)
    @run_stats[:scanned_txs] += stats[:scanned_txs].to_i
    @run_stats[:scanned_vouts] += stats[:scanned_vouts].to_i
    @run_stats[:seen_rows] += stats[:seen_rows].to_i
  end

  def merge_spent_stats!(stats)
    @run_stats[:spent_rows] += stats[:spent_rows].to_i
  end

  # ---------------------------------------------------------------------------
  # Logging
  # ---------------------------------------------------------------------------
  def update_job_progress!(current:, total:, height:)
    return if total.to_i <= 0
    return unless (current % 5).zero? || current == total

    pct = ((current.to_f / total.to_f) * 100).round(1)
    pct = [[pct, 0].max, 100].min

    job = JobRun
      .where(name: CURSOR_NAME, status: "running")
      .order(created_at: :desc)
      .first

    return unless job

    job.update!(
      progress_pct: pct,
      progress_label: "block #{height} • #{current} / #{total} blocs",
      heartbeat_at: Time.current
    )
  rescue => e
    Rails.logger.warn("[exchange_observed_scan] progress update failed: #{e.class} #{e.message}")
  end

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

  # ---------------------------------------------------------------------------
  # Flushers
  # ---------------------------------------------------------------------------

  def flush_seen!
    return if @seen_rows_buffer.empty?

    ExchangeObservedUtxo.upsert_all(
      @seen_rows_buffer,
      unique_by: :index_exchange_observed_utxos_on_txid_and_vout
    )

    @seen_rows_buffer.clear
  end

  def flush_spent!
    return if @spent_rows_buffer.empty?

    now = Time.current

    keys = @spent_rows_buffer.map { |r| [r[:txid].to_s, r[:vout].to_i] }.uniq

    existing =
      ExchangeObservedUtxo
        .where(
          txid: keys.map(&:first),
          vout: keys.map(&:last)
        )
        .index_by { |u| [u.txid.to_s, u.vout.to_i] }

    upsert_rows = []

    @spent_rows_buffer.each do |row|
      key = [row[:txid].to_s, row[:vout].to_i]
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
        spent_by_txid: row[:spent_by_txid],
        spent_day: row[:spent_day],
        spent_at: (@model_columns.include?("spent_at") ? row[:spent_at] : current.try(:spent_at)),
        spent_blockhash: (@model_columns.include?("spent_blockhash") ? row[:spent_blockhash] : current.try(:spent_blockhash)),
        spent_blockheight: (@model_columns.include?("spent_blockheight") ? row[:spent_blockheight] : current.try(:spent_blockheight)),
        seen_at: (@model_columns.include?("seen_at") ? current.try(:seen_at) : nil),
        seen_blockhash: (@model_columns.include?("seen_blockhash") ? current.try(:seen_blockhash) : nil),
        seen_blockheight: (@model_columns.include?("seen_blockheight") ? current.try(:seen_blockheight) : nil)
      }.compact
    end

    if upsert_rows.any?
      ExchangeObservedUtxo.upsert_all(
        upsert_rows,
        unique_by: :index_exchange_observed_utxos_on_txid_and_vout
      )
    end

    @spent_rows_buffer.clear
  end
end