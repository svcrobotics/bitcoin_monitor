# frozen_string_literal: true

require "set"

# app/services/cluster_scanner.rb
class ClusterScanner
  class Error < StandardError; end

  CURSOR_NAME = "cluster_scan"
  INITIAL_BLOCKS_BACK = (Integer(ENV.fetch("CLUSTER_INITIAL_BLOCKS_BACK", "50")) rescue 50)

  def self.call(from_height: nil, to_height: nil, limit: nil, rpc: nil, job_run: nil, refresh: true)
    new(
      from_height: from_height,
      to_height: to_height,
      limit: limit,
      rpc: rpc,
      job_run: job_run,
      refresh: refresh
    ).call
  end

  def initialize(from_height: nil, to_height: nil, limit: nil, rpc: nil, job_run: nil, refresh: true)
    @from_height = from_height.present? ? from_height.to_i : nil
    @to_height   = to_height.present? ? to_height.to_i : nil
    @limit       = limit.present? ? limit.to_i : nil
    @rpc         = rpc || BitcoinRpc.new(wallet: nil)
    @job_run = job_run
    @refresh = refresh

    @dirty_cluster_ids = Set.new

    @stats = {
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

  def call
    best_height = @rpc.getblockcount.to_i
    range = compute_scan_range(best_height)

    if range[:start_height] > range[:end_height]
      return {
        ok: true,
        note: "nothing to scan",
        mode: range[:mode],
        best_height: best_height,
        start_height: range[:start_height],
        end_height: range[:end_height]
      }
    end

    puts(
      "[cluster_scan] start " \
      "mode=#{range[:mode]} " \
      "start_height=#{range[:start_height]} " \
      "end_height=#{range[:end_height]}"
    )

    update_progress!(
      range[:start_height],
      range[:start_height],
      range[:end_height]
    )

    (range[:start_height]..range[:end_height]).each do |height|
      scanned = scan_block(height)
      @stats[:scanned_blocks] += 1 if scanned

      if (@stats[:scanned_blocks] % 10).zero? || height == range[:end_height]
        update_progress!(height, range[:start_height], range[:end_height])
      end

      log_progress(height)
    end

    refresh_dirty_clusters! if @refresh

    update_cursor!(range[:end_height]) if range[:mode] == :incremental

    {
      ok: true,
      mode: range[:mode],
      best_height: best_height,
      start_height: range[:start_height],
      end_height: range[:end_height],
      refresh: @refresh,
      dirty_clusters_count: @dirty_cluster_ids.size,
      dirty_cluster_ids: @refresh ? [] : @dirty_cluster_ids.to_a
    }.merge(@stats)
  end

  private

  def compute_scan_range(best_height)
    if manual_mode?
      start_height = @from_height || [0, best_height - default_manual_span + 1].max
      end_height   = @to_height || best_height

      if @limit.present? && @limit > 0
        end_height = [end_height, start_height + @limit - 1].min
      end

      return {
        mode: :manual,
        start_height: [0, start_height].max,
        end_height: [best_height, end_height].min
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

    if @limit.present? && @limit > 0
      end_height = [best_height, start_height + @limit - 1].min
    end

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
    @limit.present? && @limit > 0 ? @limit : INITIAL_BLOCKS_BACK
  end

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

  def scan_block(height)
    blockhash = @rpc.getblockhash(height)
    block = @rpc.getblock(blockhash, 3)

    Array(block["tx"]).each do |tx|
      @stats[:scanned_txs] += 1
      scan_transaction(tx, height)
    end

    true
  rescue BitcoinRpc::Error => e
    if e.message.include?("Block not available (pruned data)")
      @stats[:pruned_blocks_skipped] += 1
      puts "[cluster_scan] skip_pruned_block height=#{height}"
      return false
    end

    raise
  end

  def scan_transaction(tx, height)
    txid = tx["txid"].to_s
    return if txid.blank?
    return if coinbase_tx?(tx)

    if Array(tx["vin"]).size >= 2
      @stats[:multi_input_candidates] += 1
    end

    if AddressLink.exists?(txid: txid, link_type: "multi_input")
      @stats[:already_linked_txs] += 1
      return
    end

    grouped_inputs = Clusters::InputExtractor.call(tx)

    @stats[:input_rows_found] += grouped_inputs.sum { |g| g[:total_inputs].to_i }

    return if grouped_inputs.empty?

    if grouped_inputs.size >= 2
      @stats[:multi_address_candidates] += 1
    end

    return if grouped_inputs.size < 2

    @stats[:multi_input_txs] += 1

    ActiveRecord::Base.transaction do
      grouped_by_address = grouped_inputs.index_by { |g| g[:address] }

      address_records = Clusters::AddressWriter.call(
        grouped_inputs: grouped_by_address,
        height: height
      )

      merge_result = Clusters::ClusterMerger.call(address_records: address_records)

      @stats[:clusters_created] += merge_result.created
      @stats[:clusters_merged] += merge_result.merged

      cluster = merge_result.cluster

      @stats[:links_created] += Clusters::LinkWriter.call(
        address_records: address_records,
        txid: txid,
        height: height
      )

      mark_cluster_dirty!(cluster)
    end

    @stats[:addresses_touched] += grouped_inputs.size
  rescue BitcoinRpc::Error => e
    @stats[:tx_skipped_rpc_errors] += 1
    puts "[cluster_scan] tx_skip txid=#{txid} height=#{height} reason=#{e.message}"
  rescue StandardError => e
    raise Error, "scan_transaction failed txid=#{txid} height=#{height}: #{e.class} - #{e.message}"
  end

  def coinbase_tx?(tx)
    Array(tx["vin"]).any? { |vin| vin["coinbase"].present? }
  end

  def mark_cluster_dirty!(cluster)
    return if cluster.blank?

    @dirty_cluster_ids << cluster.id
  end

  def refresh_dirty_clusters!
    Clusters::DirtyClusterRefresher.call(
      cluster_ids: @dirty_cluster_ids.to_a
    )
  end

  def log_progress(height)
    return unless (@stats[:scanned_blocks] % 10).zero? && @stats[:scanned_blocks].positive?

    puts(
      "[cluster_scan] progress " \
      "height=#{height} " \
      "blocks=#{@stats[:scanned_blocks]} " \
      "txs=#{@stats[:scanned_txs]} " \
      "multi_input_txs=#{@stats[:multi_input_txs]} " \
      "links_created=#{@stats[:links_created]} " \
      "clusters_created=#{@stats[:clusters_created]} " \
      "clusters_merged=#{@stats[:clusters_merged]} " \
      "pruned_blocks_skipped=#{@stats[:pruned_blocks_skipped]} " \
      "tx_skipped_rpc_errors=#{@stats[:tx_skipped_rpc_errors]} " \
      "tx_skipped_missing_prevout=#{@stats[:tx_skipped_missing_prevout]}"
    )
  end

  def update_progress!(current_height, start_height, end_height)
    return if @job_run.blank?

    total = (end_height - start_height + 1)
    return if total <= 0

    done = (current_height - start_height + 1)
    pct = ((done.to_f / total) * 100).round(1)

    JobRunner.progress!(
      @job_run,
      pct: pct,
      label: "block #{current_height} / #{end_height}",
      meta: {
        start_height: start_height,
        current_height: current_height,
        end_height: end_height,
        scanned_blocks: @stats[:scanned_blocks],
        scanned_txs: @stats[:scanned_txs],
        multi_input_txs: @stats[:multi_input_txs],
        links_created: @stats[:links_created],
        clusters_created: @stats[:clusters_created],
        clusters_merged: @stats[:clusters_merged],
        pruned_blocks_skipped: @stats[:pruned_blocks_skipped]
      }
    )
  end
end