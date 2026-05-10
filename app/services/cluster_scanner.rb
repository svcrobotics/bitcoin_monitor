# frozen_string_literal: true

require "set"

# app/services/cluster_scanner.rb
class ClusterScanner
  class Error < StandardError; end

  CURSOR_NAME = "cluster_scan"
  INITIAL_BLOCKS_BACK = (Integer(ENV.fetch("CLUSTER_INITIAL_BLOCKS_BACK", "50")) rescue 50)
  ENABLE_TIMING_LOGS = ENV.fetch("CLUSTER_TIMING_LOGS", "true") == "true"
  LOCK_KEY = "cluster_scan_lock"
  LOCK_TTL = 30.minutes.to_i
  SATS_PER_BTC = 100_000_000

  def self.call(**args)
    new(**args).call
  end

  def initialize(from_height: nil, to_height: nil, limit: nil, rpc: nil, job_run: nil, refresh: true)
    @redis = ::Redis.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0"))
    @lock_acquired = false
    @from_height = from_height&.to_i
    @to_height   = to_height&.to_i
    @limit       = limit&.to_i
    @rpc         = rpc # kept for compatibility, no longer used for normal scan
    @job_run     = job_run
    @refresh     = refresh

    @dirty_cluster_ids = Set.new
    @known_linked_txids = Set.new

    @stats = default_stats
  end

  def call
    return skipped_response("lock already present") unless acquire_lock!

    best_height = layer1_best_height
    range = compute_scan_range(best_height)

    return empty_range_response(range, best_height) if range[:start_height] > range[:end_height]

    log_start(range)

    update_progress!(range[:start_height], range[:start_height], range[:end_height])

    scan_range(range)

    refresh_dirty_clusters! if @refresh
    # update_cursor!(range[:end_height]) if range[:mode] == :incremental

    build_result(range, best_height)
  ensure
    release_lock! if @lock_acquired
  end

  private

  # -------------------------
  # MAIN LOOP
  # -------------------------

  def scan_range(range)
    (range[:start_height]..range[:end_height]).each do |height|
      scanned = scan_block(height)
      @stats[:scanned_blocks] += 1 if scanned

      update_cursor!(height) if scanned && range[:mode] == :incremental

      log_progress(height)
      update_progress_if_needed(height, range)
    end
  end

  def scan_block(height)
    txids = layer1_spending_txids_for_height(height)

    linked_txids = AddressLink
      .where(txid: txids, link_type: "multi_input")
      .pluck(:txid)
      .to_set

    ActiveRecord::Base.transaction do
      txids.each do |txid|
        @stats[:scanned_txs] += 1
        scan_layer1_transaction(txid, height, linked_txids)
      end
    end

    true
  rescue StandardError => e
    raise Error, "scan_block failed height=#{height}: #{e.class} - #{e.message}"
  end

  def scan_layer1_transaction(txid, height, linked_txids)
    txid = txid.to_s
    return if txid.blank?

    if linked_txids.include?(txid)
      @stats[:already_linked_txs] += 1
      return
    end

    input_rows = layer1_inputs_for_txid(txid)
    return if input_rows.size < 2

    @stats[:multi_input_candidates] += 1

    grouped = grouped_layer1_inputs(input_rows)
    return if grouped.empty? || grouped.size < 2

    @stats[:multi_address_candidates] += 1
    @stats[:multi_input_txs] += 1
    @stats[:input_rows_found] += grouped.sum { |g| g[:total_inputs].to_i }

    address_records = timed("AddressWriter") do
      Clusters::AddressWriter.call(
        grouped_inputs: grouped.index_by { |g| g[:address] },
        height: height
      )
    end

    merge_result = timed("ClusterMerger") do
      Clusters::ClusterMerger.call(address_records: address_records)
    end

    @stats[:clusters_created] += merge_result.created
    @stats[:clusters_merged]  += merge_result.merged

    timed("LinkWriter") do
      @stats[:links_created] += Clusters::LinkWriter.call(
        address_records: address_records,
        txid: txid,
        height: height
      )
    end

    mark_cluster_dirty!(merge_result.cluster)
    @stats[:addresses_touched] += grouped.size
  rescue StandardError => e
    raise Error, "scan_layer1_transaction failed txid=#{txid} height=#{height}: #{e.class} - #{e.message}"
  end

  # -------------------------
  # LAYER 1 SOURCE
  # -------------------------

  def layer1_best_height
    ActiveRecord::Base.connection
      .exec_query("SELECT COALESCE(MAX(height), 0) AS height FROM block_buffers WHERE status = 'processed'")
      .first["height"]
      .to_i
  end

  def block_hash_for_height(height)
    ActiveRecord::Base.connection
      .exec_query(
        ActiveRecord::Base.sanitize_sql_array([
          "SELECT block_hash FROM block_buffers WHERE height = ? LIMIT 1",
          height.to_i
        ])
      )
      .first&.fetch("block_hash", nil)
  end

  def layer1_spending_txids_for_height(height)
    TxOutput
      .where(spent_block_height: height)
      .where.not(spent_txid: nil)
      .distinct
      .pluck(:spent_txid)
  end

  def layer1_inputs_for_txid(txid)
    TxOutput
      .where(spent_txid: txid)
      .where.not(address: nil)
      .where.not(amount_btc: nil)
      .pluck(:address, :amount_btc)
      .map do |address, amount_btc|
        {
          address: address,
          value_sats: btc_to_sats(amount_btc)
        }
      end
  end

  def grouped_layer1_inputs(input_rows)
    grouped = input_rows.group_by { |row| row[:address] }

    grouped.map do |address, rows|
      {
        address: address,
        total_inputs: rows.size,
        total_value_sats: rows.sum { |row| row[:value_sats].to_i }
      }
    end
  end

  def btc_to_sats(value)
    (value.to_d * SATS_PER_BTC).to_i
  end

  # -------------------------
  # TIMING HELPER
  # -------------------------

  def timed(label)
    return yield unless ENABLE_TIMING_LOGS

    t0 = Time.now
    result = yield
    puts "#{label}: #{((Time.now - t0) * 1000).round(2)}ms"
    result
  end

  # -------------------------
  # RANGE LOGIC
  # -------------------------

  def compute_scan_range(best_height)
    if manual_mode?
      start_height = @from_height || [0, best_height - default_manual_span + 1].max
      end_height   = @to_height || best_height

      if @limit&.positive?
        end_height = [end_height, start_height + @limit - 1].min
      end

      return {
        mode: :manual,
        start_height: start_height.clamp(0, best_height),
        end_height: [end_height, best_height].min
      }
    end

    cursor = scanner_cursor

    start_height =
      if cursor.last_blockheight.present?
        cursor.last_blockheight.to_i + 1
      else
        [0, best_height - INITIAL_BLOCKS_BACK + 1].max
      end

    end_height = best_height
    end_height = [start_height + @limit - 1, best_height].min if @limit&.positive?

    {
      mode: :incremental,
      start_height: start_height,
      end_height: end_height
    }
  end

  def manual_mode?
    @from_height.present? || @to_height.present?
  end

  def default_manual_span
    @limit&.positive? ? @limit : INITIAL_BLOCKS_BACK
  end

  # -------------------------
  # CURSOR
  # -------------------------

  def scanner_cursor
    @scanner_cursor ||= ScannerCursor.find_or_create_by!(name: CURSOR_NAME)
  end

  def update_cursor!(height)
    scanner_cursor.update!(
      last_blockheight: height,
      last_blockhash: block_hash_for_height(height)
    )
  end

  # -------------------------
  # DIRTY CLUSTERS
  # -------------------------

  def mark_cluster_dirty!(cluster)
    @dirty_cluster_ids << cluster.id if cluster.present?
  end

  def refresh_dirty_clusters!
    return if @dirty_cluster_ids.empty?

    Clusters::DirtyClusterRefresher.call(cluster_ids: @dirty_cluster_ids.to_a)
  end

  # -------------------------
  # LOGGING
  # -------------------------

  def log_start(range)
    puts "[cluster_scan] start source=layer1 mode=#{range[:mode]} start_height=#{range[:start_height]} end_height=#{range[:end_height]}"
  end

  def log_progress(height)
    return unless (@stats[:scanned_blocks] % 10).zero?

    puts "[cluster_scan] progress source=layer1 height=#{height} " \
         "blocks=#{@stats[:scanned_blocks]} txs=#{@stats[:scanned_txs]} " \
         "multi_input_txs=#{@stats[:multi_input_txs]} links=#{@stats[:links_created]}"
  end

  def update_progress_if_needed(height, range)
    return unless (@stats[:scanned_blocks] % 10).zero?

    update_progress!(height, range[:start_height], range[:end_height])
  end

  def update_progress!(current, start_h, end_h)
    return if @job_run.blank?

    total = (end_h - start_h + 1)
    return if total <= 0

    done = (current - start_h + 1)
    pct = ((done.to_f / total) * 100).round(1)

    JobRunner.progress!(
      @job_run,
      pct: pct,
      label: "block #{current} / #{end_h}",
      meta: @stats.merge(
        start_height: start_h,
        current_height: current,
        end_height: end_h,
        source: "layer1"
      )
    )
  end

  # -------------------------
  # RESPONSE
  # -------------------------

  def empty_range_response(range, best_height)
    {
      ok: true,
      source: "layer1",
      note: "nothing to scan",
      mode: range[:mode],
      best_height: best_height,
      start_height: range[:start_height],
      end_height: range[:end_height]
    }
  end

  def build_result(range, best_height)
    {
      ok: true,
      source: "layer1",
      mode: range[:mode],
      best_height: best_height,
      start_height: range[:start_height],
      end_height: range[:end_height],
      refresh: @refresh,
      dirty_clusters_count: @dirty_cluster_ids.size,
      dirty_cluster_ids: @refresh ? [] : @dirty_cluster_ids.to_a
    }.merge(@stats)
  end

  def default_stats
    {
      scanned_blocks: 0,
      scanned_txs: 0,
      multi_input_txs: 0,
      links_created: 0,
      clusters_created: 0,
      clusters_merged: 0,
      addresses_touched: 0,
      pruned_blocks_skipped: 0,
      tx_skipped_rpc_errors: 0,
      tx_skipped_missing_prevout: 0,
      multi_input_candidates: 0,
      already_linked_txs: 0,
      input_rows_found: 0,
      multi_address_candidates: 0
    }
  end

  def acquire_lock!
    @lock_acquired = @redis.set(
      LOCK_KEY,
      Time.current.to_i,
      nx: true,
      ex: LOCK_TTL
    )

    @lock_acquired
  end

  def release_lock!
    @redis.del(LOCK_KEY)
  end

  def skipped_response(reason)
    {
      ok: true,
      source: "layer1",
      skipped: true,
      reason: reason,
      at: Time.current
    }
  end
end