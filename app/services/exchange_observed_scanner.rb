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
# Source
# ------
# Ce scanner consomme maintenant Layer 1 :
#
#   tx_outputs
#
# Il ne rescane plus les blocs Bitcoin Core via RPC pour les outputs/spends.
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

  def self.call(days_back: nil, last_n_blocks: nil, rpc: nil)
    new(days_back: days_back, last_n_blocks: last_n_blocks, rpc: rpc).call
  end

  def initialize(days_back:, last_n_blocks:, rpc:)
    @days_back_explicit = !days_back.nil?
    @days_back          = days_back.nil? ? DAYS_BACK_DEFAULT : days_back.to_i
    @last_n_blocks      = last_n_blocks.present? ? last_n_blocks.to_i : nil
    @rpc                = rpc # kept for compatibility, not used for normal scan

    @scannable_address_set = ExchangeLike::ScannableAddressSet.new

    reset_runtime_state!
  end

  def call
    scannable = @scannable_address_set.call
    return empty_result("no operational exchange addresses") if scannable.addresses.empty?

    best_height = layer1_best_height
    range = compute_scan_range(best_height)

    if range[:start_height] > range[:end_height]
      return empty_result("nothing to scan", best_height: best_height, mode: range[:mode])
    end

    exchange_addresses = scannable.addresses.to_a

    puts "[exchange_observed_scan] start " \
         "source=layer1 " \
         "mode=#{range[:mode]} start_height=#{range[:start_height]} end_height=#{range[:end_height]} " \
         "exchange_set_size=#{exchange_addresses.size}"

    scan_range(range, exchange_addresses)

    flush_seen!
    flush_spent!

    {
      ok: true,
      source: "layer1",
      mode: range[:mode],
      scanned_blocks: @run_stats[:scanned_blocks],
      scanned_txs: @run_stats[:scanned_txs],
      scanned_vouts: @run_stats[:scanned_vouts],
      seen_rows: @run_stats[:seen_rows],
      spent_rows: @run_stats[:spent_rows],
      start_height: range[:start_height],
      end_height: range[:end_height],
      best_height: best_height,
      exchange_set_size: exchange_addresses.size
    }
  end

  private

  def reset_runtime_state!
    @seen_rows_buffer = []
    @spent_rows_buffer = []

    @block_hash_cache = {}
    @block_time_cache = {}

    @run_stats = {
      scanned_blocks: 0,
      scanned_txs: 0,
      scanned_vouts: 0,
      seen_rows: 0,
      spent_rows: 0
    }
  end

  def empty_result(note, best_height: nil, mode: nil)
    {
      ok: true,
      source: "layer1",
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

      start_height = find_first_height_for_time(@days_back.days.ago, best_height)
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
    row =
      TxOutput
        .where("block_time >= ?", start_time)
        .where.not(block_height: nil)
        .order(block_height: :asc)
        .limit(1)
        .pluck(:block_height)
        .first

    row || [0, best_height - INITIAL_BLOCKS_BACK + 1].max
  end

  # ---------------------------------------------------------------------------
  # Cursor
  # ---------------------------------------------------------------------------

  def scanner_cursor
    @scanner_cursor ||= ScannerCursor.find_or_create_by!(name: CURSOR_NAME)
  end

  def update_cursor!(height)
    scanner_cursor.update!(
      last_blockheight: height,
      last_blockhash: block_hash_for_height(height)
    )
  end

  # ---------------------------------------------------------------------------
  # Main scan loop
  # ---------------------------------------------------------------------------

  def scan_range(range, exchange_addresses)
    start_height = range[:start_height].to_i
    end_height   = range[:end_height].to_i
    total_blocks = end_height - start_height + 1

    (start_height..end_height).each_with_index do |height, index|
      update_job_progress!(
        current: index + 1,
        total: total_blocks,
        height: height,
        force: true,
        label_suffix: "starting block"
      )

      scan_height(height, exchange_addresses)

      update_cursor!(height) if range[:mode] == :incremental

      update_job_progress!(
        current: index + 1,
        total: total_blocks,
        height: height,
        force: true,
        label_suffix: "finished block"
      )
    end
  end

  def scan_height(height, exchange_addresses)
    @run_stats[:scanned_blocks] += 1

    log_progress(
      @run_stats[:scanned_blocks],
      height,
      @seen_rows_buffer.size,
      @spent_rows_buffer.size,
      exchange_addresses.size
    )

    process_layer1_height(height, exchange_addresses)
  end

  # ---------------------------------------------------------------------------
  # Layer 1 source
  # ---------------------------------------------------------------------------

  def layer1_best_height
    BlockBufferModel
      .where(status: "processed")
      .maximum(:height)
      .to_i
  end

  def block_hash_for_height(height)
    height = height.to_i
    @block_hash_cache[height] ||= BlockBufferModel.where(height: height).pick(:block_hash)
  end

  def block_time_for_height(height)
    height = height.to_i
    @block_time_cache[height] ||= BlockBufferModel.where(height: height).pick(:block_time)
  end

  def process_layer1_height(height, exchange_addresses)
    outputs = TxOutput.where(block_height: height)

    @run_stats[:scanned_vouts] += outputs.count
    @run_stats[:scanned_txs] += outputs.distinct.count(:txid)

    process_layer1_seen_outputs(outputs, exchange_addresses)
    process_layer1_spent_outputs(height)

    flush_seen! if @seen_rows_buffer.size >= BATCH_UPSERT
    flush_spent! if @spent_rows_buffer.size >= BATCH_UPSERT
  end

  def process_layer1_seen_outputs(outputs, exchange_addresses)
    now = Time.current

    outputs.where(address: exchange_addresses).find_each(batch_size: 1_000) do |output|
      @seen_rows_buffer << build_seen_row(output, now)
      @run_stats[:seen_rows] += 1
    end
  end

  def build_seen_row(output, now)
    spent_block_time = output.spent_block_height.present? ? block_time_for_height(output.spent_block_height) : nil
    spent_blockhash = output.spent_block_height.present? ? block_hash_for_height(output.spent_block_height) : nil

    row = {
      txid: output.txid,
      vout: output.vout,
      address: output.address,
      value_btc: output.amount_btc,
      seen_day: output.block_time&.in_time_zone(TZ)&.to_date || Date.current,
      source: "layer1",
      created_at: now,
      updated_at: now
    }

    row[:spent_at] = spent_block_time || now if output.spent && model_columns.include?("spent_at")
    row[:spent_day] = spent_block_time&.in_time_zone(TZ)&.to_date || Date.current if output.spent && model_columns.include?("spent_day")
    row[:spent_by_txid] = output.spent_txid if output.spent_txid.present? && model_columns.include?("spent_by_txid")
    row[:spent_blockheight] = output.spent_block_height if output.spent_block_height.present? && model_columns.include?("spent_blockheight")
    row[:spent_blockhash] = spent_blockhash if spent_blockhash.present? && model_columns.include?("spent_blockhash")
    row[:seen_blockheight] = output.block_height if model_columns.include?("seen_blockheight")
    row[:seen_blockhash] = output.block_hash if model_columns.include?("seen_blockhash")
    row[:seen_at] = output.block_time if model_columns.include?("seen_at")

    row
  end

  def process_layer1_spent_outputs(height)
    now = Time.current
    spent_block_time = block_time_for_height(height)
    spent_day = spent_block_time&.in_time_zone(TZ)&.to_date || Date.current
    spent_blockhash = block_hash_for_height(height)

    TxOutput
      .where(spent: true, spent_block_height: height)
      .where.not(spent_txid: nil)
      .find_each(batch_size: 1_000) do |output|
      @spent_rows_buffer << {
        txid: output.txid,
        vout: output.vout,
        spent_by_txid: output.spent_txid,
        spent_day: spent_day,
        spent_at: spent_block_time || now,
        spent_blockheight: output.spent_block_height,
        spent_blockhash: model_columns.include?("spent_blockhash") ? spent_blockhash : nil
      }.compact

      @run_stats[:spent_rows] += 1
    end
  end

  # ---------------------------------------------------------------------------
  # Logging
  # ---------------------------------------------------------------------------

  def update_job_progress!(current:, total:, height:, force: false, label_suffix: nil)
    return if total.to_i <= 0
    return unless force || (current % 5).zero? || current == total

    pct = ((current.to_f / total.to_f) * 100).round(1)
    pct = [[pct, 0].max, 100].min

    label = "block #{height} • #{current} / #{total} blocs"
    label = "#{label} • #{label_suffix}" if label_suffix.present?

    job = JobRun
      .where(name: CURSOR_NAME, status: "running")
      .order(created_at: :desc)
      .first

    return unless job

    job.update!(
      progress_pct: pct,
      progress_label: label,
      heartbeat_at: Time.current
    )
  rescue StandardError => e
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

    puts "[exchange_observed_scan] progress " \
         "source=layer1 " \
         "blocks=#{scanned_blocks} height=#{height} " \
         "exchange_set_size=#{exchange_set_size} " \
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

    keys = @seen_rows_buffer.flat_map(&:keys).uniq

    rows = @seen_rows_buffer.map do |row|
      keys.index_with { |key| row[key] }
    end

    ExchangeObservedUtxo.upsert_all(
      rows,
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
        .where(txid: keys.map(&:first), vout: keys.map(&:last))
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
        spent_at: (model_columns.include?("spent_at") ? row[:spent_at] : current.try(:spent_at)),
        spent_blockhash: (model_columns.include?("spent_blockhash") ? row[:spent_blockhash] : current.try(:spent_blockhash)),
        spent_blockheight: (model_columns.include?("spent_blockheight") ? row[:spent_blockheight] : current.try(:spent_blockheight)),
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

    @spent_rows_buffer.clear
  end
end