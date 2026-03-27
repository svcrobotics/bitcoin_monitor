# frozen_string_literal: true

# app/services/exchange_address_builder.rb
#
# ExchangeAddressBuilder
# ======================
#
# Objectif
# --------
# Construire / enrichir le set `exchange_addresses` directement depuis
# la blockchain Bitcoin, sans dépendre de WhaleAlert.
#
# Modes de fonctionnement
# -----------------------
# 1. Mode incrémental (par défaut)
#    - reprend depuis ScannerCursor
#    - traite uniquement les nouveaux blocs
#    - met à jour le curseur à la fin
#
# 2. Mode manuel / backfill
#    - si blocks_back est fourni explicitement
#    - ou si days_back est fourni explicitement
#    - permet un scan volontaire d'une fenêtre
#    - ne met pas à jour le curseur
#
# Philosophie V1
# --------------
# Cette V1 reste volontairement simple :
#
# - on scanne les blocs via RPC ;
# - on analyse les transactions de chaque bloc ;
# - on apprend principalement depuis les OUTPUTS ;
# - on agrège les adresses observées ;
# - on filtre le bruit avant d'écrire en base ;
# - on met à jour `exchange_addresses`.
#
# Pourquoi apprendre depuis les OUTPUTS ?
# --------------------------------------
# Pour une première version "builder depuis la blockchain", apprendre depuis
# les outputs est plus robuste et plus simple que remonter systématiquement
# les inputs historiques :
#
# - on évite une dépendance forte à getrawtransaction sur les tx précédentes ;
# - on reste compatible avec un fonctionnement simple en environnement pruned ;
# - les données nécessaires sont disponibles directement dans `getblock(..., 2)`.
#
# Ce que produit ce builder
# -------------------------
# Une table `exchange_addresses` contenant des adresses candidates
# "exchange-like", avec :
#
# - address
# - occurrences
# - confidence
# - first_seen_at
# - last_seen_at
# - source
#
# Important
# ---------
# Ce builder NE cherche PAS à identifier formellement un exchange précis.
# Il produit seulement un set d'adresses candidates à fort signal relatif.
#
# Limitations assumées
# --------------------
# - faux positifs possibles ;
# - faux négatifs possibles ;
# - heuristiques simples ;
# - pas de clustering ;
# - pas de distinction hot wallet / cold wallet.
#
# Exécution
# ---------
#   ExchangeAddressBuilder.call
#   ExchangeAddressBuilder.call(days_back: 7)
#   ExchangeAddressBuilder.call(blocks_back: 100)
#   ExchangeAddressBuilder.call(blocks_back: 10, reset: true)
#
# Source écrite dans la table
# ---------------------------
#   blockchain_outputs_v1
#
require "bigdecimal"
require "set"

class ExchangeAddressBuilder
  CURSOR_NAME = "exchange_address_builder"

  # ---------------------------------------------------------------------------
  # Configuration
  # ---------------------------------------------------------------------------

  DEFAULT_DAYS_BACK =
    begin
      v = ENV["EXCHANGE_ADDR_DAYS_BACK"]
      v.present? ? Integer(v) : nil
    rescue
      nil
    end

  DEFAULT_BLOCKS_BACK =
    begin
      v = ENV["EXCHANGE_ADDR_BLOCKS_BACK"]
      v.present? ? Integer(v) : nil
    rescue
      nil
    end

  INITIAL_BLOCKS_BACK =
    begin
      v = ENV["EXCHANGE_ADDR_INITIAL_BLOCKS_BACK"]
      v.present? ? Integer(v) : 50
    rescue
      50
    end

  BLOCKS_PER_DAY = Integer(ENV.fetch("EXCHANGE_ADDR_BLOCKS_PER_DAY", "144")) rescue 144

  # Filtres outputs
  MIN_OUTPUT_BTC = ENV.fetch("EXCHANGE_ADDR_MIN_OUTPUT_BTC", "0.01").to_d rescue 0.01.to_d
  MAX_OUTPUT_BTC = ENV.fetch("EXCHANGE_ADDR_MAX_OUTPUT_BTC", "500").to_d rescue 500.to_d

  # Filtrage avant persistance
  MIN_OCCURRENCES_TO_KEEP = Integer(ENV.fetch("EXCHANGE_ADDR_MIN_OCCURRENCES_TO_KEEP", "3")) rescue 3
  MIN_TX_COUNT_TO_KEEP    = Integer(ENV.fetch("EXCHANGE_ADDR_MIN_TX_COUNT_TO_KEEP", "2")) rescue 2
  MIN_ACTIVE_DAYS_TO_KEEP = Integer(ENV.fetch("EXCHANGE_ADDR_MIN_ACTIVE_DAYS_TO_KEEP", "1")) rescue 1

  LOG_EVERY_BLOCKS = Integer(ENV.fetch("EXCHANGE_ADDR_LOG_EVERY_BLOCKS", "25")) rescue 25

  # Flush intermédiaire mémoire
  FLUSH_EVERY_ADDRESSES = Integer(ENV.fetch("EXCHANGE_ADDR_FLUSH_EVERY_ADDRESSES", "20000")) rescue 20_000

  SOURCE_NAME = "blockchain_outputs_v1"

  # ---------------------------------------------------------------------------
  # API publique
  # ---------------------------------------------------------------------------

  def self.call(days_back: DEFAULT_DAYS_BACK, blocks_back: DEFAULT_BLOCKS_BACK, reset: false)
    new(days_back: days_back, blocks_back: blocks_back, reset: reset).call
  end

  def initialize(days_back:, blocks_back:, reset:)
    @days_back_explicit   = !days_back.nil?
    @blocks_back_explicit = !blocks_back.nil?

    @days_back   = days_back.nil? ? DEFAULT_DAYS_BACK : days_back.to_i
    @blocks_back = blocks_back.present? ? blocks_back.to_i : nil
    @reset       = !!reset

    @rpc = BitcoinRpc.new(wallet: nil) rescue BitcoinRpc.new
    @desc_cache = {}

    @stats = {}

    @run_stats = {
      scanned_blocks: 0,
      scanned_txs: 0,
      scanned_vouts: 0,
      learned_outputs: 0,
      skipped_coinbase_txs: 0,
      skipped_nulldata_outputs: 0,
      skipped_small_outputs: 0,
      skipped_large_outputs: 0,
      skipped_blank_addresses: 0,
      kept_addresses: 0,
      filtered_addresses: 0,
      flushes: 0
    }
  end

  def call
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    reset_exchange_addresses! if @reset

    best_height = @rpc.getblockcount.to_i
    range = compute_scan_range(best_height)

    if range[:start_height] > range[:end_height]
      puts "[exchange_addr_builder] nothing to scan mode=#{range[:mode]} "\
           "start_height=#{range[:start_height]} end_height=#{range[:end_height]}"
      return true
    end

    puts "[exchange_addr_builder] start "\
         "mode=#{range[:mode]} best_height=#{best_height} "\
         "start_height=#{range[:start_height]} end_height=#{range[:end_height]} "\
         "reset=#{@reset} flush_every_addresses=#{FLUSH_EVERY_ADDRESSES} "\
         "min_output_btc=#{MIN_OUTPUT_BTC.to_s('F')} max_output_btc=#{MAX_OUTPUT_BTC.to_s('F')} "\
         "min_occ_to_keep=#{MIN_OCCURRENCES_TO_KEEP} min_tx_to_keep=#{MIN_TX_COUNT_TO_KEEP}"

    (range[:start_height]..range[:end_height]).each do |height|
      blockhash = @rpc.getblockhash(height)
      block = @rpc.getblock(blockhash, 2)

      @run_stats[:scanned_blocks] += 1
      log_progress(height, range[:start_height], range[:end_height], block)

      process_block(block)
      flush_if_needed!
    rescue BitcoinRpc::Error => e
      puts "[exchange_addr_builder] skip height=#{height} rpc_error=#{e.message}"
      next
    end

    flush_aggregates!

    update_cursor!(range[:end_height]) if range[:mode] == :incremental

    dt = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

    puts "[exchange_addr_builder] done "\
         "mode=#{range[:mode]} "\
         "duration_s=#{dt.round(2)} "\
         "aggregated_addresses_in_memory=#{@stats.size} "\
         "kept_addresses=#{@run_stats[:kept_addresses]} "\
         "filtered_addresses=#{@run_stats[:filtered_addresses]} "\
         "flushes=#{@run_stats[:flushes]} "\
         "scanned_blocks=#{@run_stats[:scanned_blocks]} "\
         "scanned_txs=#{@run_stats[:scanned_txs]} "\
         "scanned_vouts=#{@run_stats[:scanned_vouts]} "\
         "learned_outputs=#{@run_stats[:learned_outputs]} "\
         "exchange_addresses_total=#{ExchangeAddress.count}"

    true
  end

  private

  # ---------------------------------------------------------------------------
  # Scan range
  # ---------------------------------------------------------------------------

  def compute_scan_range(best_height)
    if manual_mode?
      if @blocks_back.present? && @blocks_back.positive?
        start_height = [0, best_height - @blocks_back + 1].max
        return { mode: :manual_blocks_back, start_height: start_height, end_height: best_height }
      end

      if @days_back.present? && @days_back.positive?
        blocks_back = [1, @days_back * BLOCKS_PER_DAY].max
        start_height = [0, best_height - blocks_back + 1].max
        return { mode: :manual_days_back, start_height: start_height, end_height: best_height }
      end
    end

    cursor = builder_cursor
    if cursor.last_blockheight.present?
      start_height = cursor.last_blockheight.to_i + 1
      { mode: :incremental, start_height: start_height, end_height: best_height }
    else
      start_height = [0, best_height - INITIAL_BLOCKS_BACK + 1].max
      { mode: :incremental, start_height: start_height, end_height: best_height }
    end
  end

  def manual_mode?
    @blocks_back_explicit || @days_back_explicit || @reset
  end

  # ---------------------------------------------------------------------------
  # Cursor
  # ---------------------------------------------------------------------------

  def builder_cursor
    @builder_cursor ||= ScannerCursor.find_or_create_by!(name: CURSOR_NAME)
  end

  def update_cursor!(height)
    blockhash = @rpc.getblockhash(height)

    builder_cursor.update!(
      last_blockheight: height,
      last_blockhash: blockhash
    )
  end

  # ---------------------------------------------------------------------------
  # Scan blockchain
  # ---------------------------------------------------------------------------

  def process_block(block)
    block_time = block_time_from_block(block)

    Array(block["tx"]).each do |tx|
      process_transaction(tx, block_time: block_time)
    end
  end

  def process_transaction(tx, block_time:)
    return if tx.blank?

    @run_stats[:scanned_txs] += 1

    txid = tx["txid"].to_s
    return if txid.blank?

    if coinbase_transaction?(tx)
      @run_stats[:skipped_coinbase_txs] += 1
      return
    end

    Array(tx["vout"]).each do |vout|
      @run_stats[:scanned_vouts] += 1
      process_vout(vout, txid: txid, seen_at: block_time)
    end
  end

  def process_vout(vout, txid:, seen_at:)
    return if vout.blank?

    value =
      begin
        BigDecimal(vout["value"].to_s)
      rescue
        0.to_d
      end

    return if value <= 0

    if value < MIN_OUTPUT_BTC
      @run_stats[:skipped_small_outputs] += 1
      return
    end

    if value > MAX_OUTPUT_BTC
      @run_stats[:skipped_large_outputs] += 1
      return
    end

    spk = vout["scriptPubKey"] || {}

    if spk["type"].to_s == "nulldata"
      @run_stats[:skipped_nulldata_outputs] += 1
      return
    end

    addr = scriptpubkey_address(spk)
    if addr.blank?
      @run_stats[:skipped_blank_addresses] += 1
      return
    end

    @run_stats[:learned_outputs] += 1

    learn_address!(
      addr,
      txid: txid,
      value_btc: value,
      seen_at: seen_at
    )
  end

  # ---------------------------------------------------------------------------
  # Apprentissage / agrégation
  # ---------------------------------------------------------------------------

  def learn_address!(addr, txid:, value_btc:, seen_at:)
    row = (@stats[addr] ||= {
      occurrences: 0,
      total_received_btc: 0.to_d,
      txids: Set.new,
      first_seen_at: nil,
      last_seen_at: nil,
      seen_days: Set.new
    })

    row[:occurrences] += 1
    row[:total_received_btc] += value_btc
    row[:txids] << txid
    row[:first_seen_at] = [row[:first_seen_at], seen_at].compact.min
    row[:last_seen_at]  = [row[:last_seen_at], seen_at].compact.max
    row[:seen_days] << seen_at.to_date.to_s
  end

  # ---------------------------------------------------------------------------
  # Flush intermédiaire mémoire
  # ---------------------------------------------------------------------------

  def flush_if_needed!
    return if @stats.size < FLUSH_EVERY_ADDRESSES

    flush_aggregates!
  end

  # ---------------------------------------------------------------------------
  # Persistance batch SQL
  # ---------------------------------------------------------------------------

  def flush_aggregates!
    return if @stats.empty?

    current_size = @stats.size
    kept_rows = []
    filtered = 0

    @stats.each do |addr, stat|
      if keep_stat?(stat)
        kept_rows << build_batch_row(addr, stat)
        @run_stats[:kept_addresses] += 1
      else
        filtered += 1
        @run_stats[:filtered_addresses] += 1
      end
    end

    batch_upsert_exchange_addresses!(kept_rows) if kept_rows.any?

    @run_stats[:flushes] += 1

    puts "[exchange_addr_builder] flush "\
         "flush_no=#{@run_stats[:flushes]} "\
         "stats_size=#{current_size} kept=#{kept_rows.size} filtered=#{filtered}"

    @stats.clear
  end

  def build_batch_row(addr, stat)
    {
      address: addr,
      occurrences_inc: stat[:occurrences].to_i,
      confidence_inc: confidence_increment_for(stat).to_i,
      seen_at_min: stat[:first_seen_at],
      seen_at_max: stat[:last_seen_at],
      source: SOURCE_NAME
    }
  end

  def batch_upsert_exchange_addresses!(rows)
    return if rows.empty?

    now = Time.current
    addresses = rows.map { |r| r[:address] }

    existing_by_address =
      ExchangeAddress
        .where(address: addresses)
        .index_by(&:address)

    upsert_rows = rows.map do |r|
      existing = existing_by_address[r[:address]]

      merged_source =
        if existing&.source.present?
          parts = existing.source.to_s.split(",").map(&:strip).reject(&:blank?)
          parts << r[:source] unless parts.include?(r[:source])
          parts.join(",")
        else
          r[:source]
        end

      {
        address: r[:address],
        source: merged_source,
        occurrences: existing ? existing.occurrences.to_i + r[:occurrences_inc].to_i : r[:occurrences_inc].to_i,
        confidence: [
          100,
          (existing ? existing.confidence.to_i : 0) + r[:confidence_inc].to_i
        ].min,
        first_seen_at: [existing&.first_seen_at, r[:seen_at_min]].compact.min,
        last_seen_at:  [existing&.last_seen_at,  r[:seen_at_max]].compact.max,
        created_at: existing&.created_at || now,
        updated_at: now
      }
    end

    ExchangeAddress.upsert_all(
      upsert_rows,
      unique_by: :index_exchange_addresses_on_address
    )
  end

  # ---------------------------------------------------------------------------
  # Règles heuristiques
  # ---------------------------------------------------------------------------

  def keep_stat?(stat)
    occurrences = stat[:occurrences].to_i
    tx_count    = stat[:txids].size
    active_days = stat[:seen_days].size

    return true if occurrences >= MIN_OCCURRENCES_TO_KEEP
    return true if tx_count >= MIN_TX_COUNT_TO_KEEP
    return true if active_days >= MIN_ACTIVE_DAYS_TO_KEEP && occurrences >= 2

    false
  end

  def confidence_increment_for(stat)
    occurrences = stat[:occurrences].to_i
    tx_count    = stat[:txids].size
    active_days = stat[:seen_days].size
    total_btc   = stat[:total_received_btc]

    score = 0
    score += occurrences
    score += [tx_count / 3, 10].min
    score += [active_days * 2, 20].min

    score +=
      if total_btc >= 100.to_d
        20
      elsif total_btc >= 20.to_d
        10
      elsif total_btc >= 5.to_d
        5
      else
        0
      end

    [[score, 1].max, 100].min
  end

  # ---------------------------------------------------------------------------
  # Helpers blockchain / RPC
  # ---------------------------------------------------------------------------

  def coinbase_transaction?(tx)
    Array(tx["vin"]).any? { |vin| vin["coinbase"].present? }
  end

  def block_time_from_block(block)
    t = block["time"] || block["mediantime"]
    Time.at(t.to_i)
  rescue
    Time.current
  end

  def scriptpubkey_address(spk)
    addr = spk["address"] || Array(spk["addresses"]).first
    return addr if addr.present?

    desc = spk["desc"].to_s
    return nil if desc.blank?

    @desc_cache[desc] ||= Array(@rpc.deriveaddresses(desc)).first
  rescue BitcoinRpc::Error
    nil
  rescue
    nil
  end

  # ---------------------------------------------------------------------------
  # Maintenance / logs
  # ---------------------------------------------------------------------------

  def reset_exchange_addresses!
    puts "[exchange_addr_builder] reset exchange_addresses"
    ExchangeAddress.delete_all
  end

  def log_progress(height, start_height, end_height, block)
    return unless (@run_stats[:scanned_blocks] % LOG_EVERY_BLOCKS).zero?

    tx_count = Array(block["tx"]).size

    puts "[exchange_addr_builder] progress "\
         "height=#{height} scanned_blocks=#{@run_stats[:scanned_blocks]} "\
         "range=#{start_height}..#{end_height} tx_count=#{tx_count} "\
         "aggregated_addresses=#{@stats.size} learned_outputs=#{@run_stats[:learned_outputs]}"
  end
end