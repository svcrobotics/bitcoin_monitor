# frozen_string_literal: true

# app/services/exchange_address_builder.rb
#
# ExchangeAddressBuilder
# ======================
#
# Objectif
# --------
# Construire / enrichir le set `exchange_addresses` depuis le Layer 1.
#
# Source
# ------
# Ce builder consomme maintenant :
#
#   tx_outputs
#
# Il ne rescane plus Bitcoin Core via RPC.
#
# Rôle architectural
# ------------------
# Layer 1 extrait les outputs bruts.
# ExchangeAddressBuilder transforme ces outputs en adresses candidates
# "exchange-like".
#
require "bigdecimal"

class ExchangeAddressBuilder
  CURSOR_NAME = "exchange_address_builder"

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

  MIN_OUTPUT_BTC = ENV.fetch("EXCHANGE_ADDR_MIN_OUTPUT_BTC", "0.01").to_d rescue 0.01.to_d
  MAX_OUTPUT_BTC = ENV.fetch("EXCHANGE_ADDR_MAX_OUTPUT_BTC", "500").to_d rescue 500.to_d

  MIN_OCCURRENCES_TO_KEEP = Integer(ENV.fetch("EXCHANGE_ADDR_MIN_OCCURRENCES_TO_KEEP", "3")) rescue 3
  MIN_TX_COUNT_TO_KEEP    = Integer(ENV.fetch("EXCHANGE_ADDR_MIN_TX_COUNT_TO_KEEP", "2")) rescue 2
  MIN_ACTIVE_DAYS_TO_KEEP = Integer(ENV.fetch("EXCHANGE_ADDR_MIN_ACTIVE_DAYS_TO_KEEP", "1")) rescue 1

  LOG_EVERY_BLOCKS = Integer(ENV.fetch("EXCHANGE_ADDR_LOG_EVERY_BLOCKS", "25")) rescue 25
  FLUSH_EVERY_ADDRESSES = Integer(ENV.fetch("EXCHANGE_ADDR_FLUSH_EVERY_ADDRESSES", "20000")) rescue 20_000

  SOURCE_NAME = "layer1_outputs_v1"

  def self.call(days_back: DEFAULT_DAYS_BACK, blocks_back: DEFAULT_BLOCKS_BACK, reset: false)
    new(days_back: days_back, blocks_back: blocks_back, reset: reset).call
  end

  def initialize(days_back:, blocks_back:, reset:)
    @days_back = days_back.nil? ? DEFAULT_DAYS_BACK : days_back.to_i
    @blocks_back = blocks_back.present? ? blocks_back.to_i : nil
    @reset = !!reset

    @aggregator = ExchangeLike::AddressAggregator.new

    @address_filter = ExchangeLike::AddressFilter.new(
      min_occurrences_to_keep: MIN_OCCURRENCES_TO_KEEP,
      min_tx_count_to_keep: MIN_TX_COUNT_TO_KEEP,
      min_active_days_to_keep: MIN_ACTIVE_DAYS_TO_KEEP
    )

    @address_scorer = ExchangeLike::AddressScorer.new
    @address_upserter = ExchangeLike::AddressUpserter.new(source_name: SOURCE_NAME)

    reset_runtime_state!
  end

  def call
    started_at = monotonic_now

    reset_exchange_addresses! if @reset

    best_height = layer1_best_height
    range = resolve_scan_range(best_height)

    if range.empty?
      puts "[exchange_addr_builder] nothing to scan " \
           "source=layer1 mode=#{range.mode} start_height=#{range.start_height.inspect} " \
           "end_height=#{range.end_height.inspect} best_height=#{range.best_height}"
      return true
    end

    log_start(range)

    scan_range(range)
    flush_aggregates!

    update_cursor!(range.end_height) if range.mode == :incremental
    ExchangeLike::ScannableAddressesCache.invalidate!
    log_done(range, started_at)

    true
  end

  private

  def reset_runtime_state!
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
      flushes: 0,
      upsert_rows: 0,
      missing_layer1_blocks: 0
    }
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def layer1_best_height
    BlockBufferModel
      .where(status: "processed")
      .maximum(:height)
      .to_i
  end

  def resolve_scan_range(best_height)
    ExchangeLike::ScanRangeResolver.new(
      best_height: best_height,
      cursor_name: CURSOR_NAME,
      days_back: @days_back,
      blocks_back: @blocks_back,
      initial_blocks_back: INITIAL_BLOCKS_BACK,
      blocks_per_day: BLOCKS_PER_DAY,
      reset: @reset
    ).call
  end

  def builder_cursor
    @builder_cursor ||= ScannerCursor.find_or_create_by!(name: CURSOR_NAME)
  end

  def update_cursor!(height)
    builder_cursor.update!(
      last_blockheight: height,
      last_blockhash: block_hash_for_height(height)
    )
  end

  def block_hash_for_height(height)
    BlockBufferModel.where(height: height.to_i).pick(:block_hash)
  end

  def scan_range(range)
    (range.start_height..range.end_height).each do |height|
      scan_height(height, range)
    end
  end

  def scan_height(height, range)
    outputs = TxOutput.where(block_height: height)

    if outputs.none?
      @run_stats[:missing_layer1_blocks] += 1
      log_missing_layer1_block(height)
      return
    end

    @run_stats[:scanned_blocks] += 1
    @run_stats[:scanned_vouts] += outputs.count
    @run_stats[:scanned_txs] += outputs.distinct.count(:txid)

    process_layer1_outputs(outputs)
    log_progress(height, range.start_height, range.end_height)

    flush_if_needed!
  end

  def process_layer1_outputs(outputs)
    outputs
      .where(amount_btc: MIN_OUTPUT_BTC..MAX_OUTPUT_BTC)
      .where.not(address: [nil, ""])
      .find_each(batch_size: 1_000) do |output|
      learn_output(output)
    end
  end

  def learn_output(output)
    @aggregator.learn(
      ExchangeLike::OutputCandidateExtractor::Candidate.new(
        address: output.address,
        txid: output.txid,
        value_btc: BigDecimal(output.amount_btc.to_s),
        seen_at: output.block_time || Time.current
      )
    )

    @run_stats[:learned_outputs] += 1
  end

  def flush_if_needed!
    return if @aggregator.size < FLUSH_EVERY_ADDRESSES

    flush_aggregates!
  end

  def flush_aggregates!
    return if @aggregator.empty?

    current_size = @aggregator.size
    kept_rows = []
    filtered = 0

    @aggregator.each do |addr, stat|
      if @address_filter.keep?(stat)
        kept_rows << build_batch_row(addr, stat)
        @run_stats[:kept_addresses] += 1
      else
        filtered += 1
        @run_stats[:filtered_addresses] += 1
      end
    end

    if kept_rows.any?
      result = @address_upserter.call(kept_rows)
      @run_stats[:upsert_rows] += result.upsert_rows_count
    end

    @run_stats[:flushes] += 1

    puts "[exchange_addr_builder] flush " \
         "source=layer1 " \
         "flush_no=#{@run_stats[:flushes]} " \
         "stats_size=#{current_size} kept=#{kept_rows.size} filtered=#{filtered}"

    @aggregator.clear
  end

  def build_batch_row(addr, stat)
    {
      address: addr,
      occurrences_inc: stat[:occurrences].to_i,
      confidence_inc: @address_scorer.score_increment(stat).to_i,
      seen_at_min: stat[:first_seen_at],
      seen_at_max: stat[:last_seen_at],
      source: SOURCE_NAME
    }
  end

  def reset_exchange_addresses!
    puts "[exchange_addr_builder] reset exchange_addresses"
    ExchangeAddress.delete_all
  end

  def log_start(range)
    puts "[exchange_addr_builder] start " \
         "source=layer1 " \
         "mode=#{range.mode} best_height=#{range.best_height} " \
         "start_height=#{range.start_height} end_height=#{range.end_height} " \
         "cursor_last_blockheight=#{range.cursor_last_blockheight.inspect} " \
         "blocks_count=#{range.blocks_count} " \
         "reset=#{@reset} flush_every_addresses=#{FLUSH_EVERY_ADDRESSES} " \
         "min_output_btc=#{MIN_OUTPUT_BTC.to_s('F')} max_output_btc=#{MAX_OUTPUT_BTC.to_s('F')} " \
         "min_occ_to_keep=#{MIN_OCCURRENCES_TO_KEEP} " \
         "min_tx_to_keep=#{MIN_TX_COUNT_TO_KEEP} " \
         "min_active_days_to_keep=#{MIN_ACTIVE_DAYS_TO_KEEP}"
  end

  def log_done(range, started_at)
    duration_s = monotonic_now - started_at

    puts "[exchange_addr_builder] done " \
         "source=layer1 " \
         "mode=#{range.mode} " \
         "duration_s=#{duration_s.round(2)} " \
         "blocks_count=#{range.blocks_count} " \
         "aggregated_addresses_in_memory=#{@aggregator.size} " \
         "kept_addresses=#{@run_stats[:kept_addresses]} " \
         "filtered_addresses=#{@run_stats[:filtered_addresses]} " \
         "flushes=#{@run_stats[:flushes]} " \
         "upsert_rows=#{@run_stats[:upsert_rows]} " \
         "missing_layer1_blocks=#{@run_stats[:missing_layer1_blocks]} " \
         "scanned_blocks=#{@run_stats[:scanned_blocks]} " \
         "scanned_txs=#{@run_stats[:scanned_txs]} " \
         "scanned_vouts=#{@run_stats[:scanned_vouts]} " \
         "learned_outputs=#{@run_stats[:learned_outputs]} " \
         "exchange_addresses_total=#{ExchangeAddress.count}"
  end

  def log_progress(height, start_height, end_height)
    return unless (@run_stats[:scanned_blocks] % LOG_EVERY_BLOCKS).zero?

    puts "[exchange_addr_builder] progress " \
         "source=layer1 " \
         "height=#{height} scanned_blocks=#{@run_stats[:scanned_blocks]} " \
         "range=#{start_height}..#{end_height} " \
         "aggregated_addresses=#{@aggregator.size} learned_outputs=#{@run_stats[:learned_outputs]}"
  end

  def log_missing_layer1_block(height)
    puts "[exchange_addr_builder] skip " \
         "source=layer1 height=#{height} reason=no_tx_outputs"
  end
end