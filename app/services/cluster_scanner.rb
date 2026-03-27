# frozen_string_literal: true

require "set"

# app/services/cluster_scanner.rb
class ClusterScanner
  class Error < StandardError; end

  CURSOR_NAME = "cluster_scan"
  INITIAL_BLOCKS_BACK = (Integer(ENV.fetch("CLUSTER_INITIAL_BLOCKS_BACK", "50")) rescue 50)

  def self.call(from_height: nil, to_height: nil, limit: nil, rpc: nil)
    new(
      from_height: from_height,
      to_height: to_height,
      limit: limit,
      rpc: rpc
    ).call
  end

  def initialize(from_height: nil, to_height: nil, limit: nil, rpc: nil)
    @from_height = from_height.present? ? from_height.to_i : nil
    @to_height   = to_height.present? ? to_height.to_i : nil
    @limit       = limit.present? ? limit.to_i : nil
    @rpc         = rpc || BitcoinRpc.new(wallet: nil)

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
      tx_skipped_missing_prevout: 0
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

    (range[:start_height]..range[:end_height]).each do |height|
      scanned = scan_block(height)
      @stats[:scanned_blocks] += 1 if scanned
      log_progress(height)
    end

    refresh_dirty_clusters!

    update_cursor!(range[:end_height]) if range[:mode] == :incremental

    {
      ok: true,
      mode: range[:mode],
      best_height: best_height,
      start_height: range[:start_height],
      end_height: range[:end_height]
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
    return if AddressLink.exists?(txid: txid, link_type: "multi_input")

    input_rows = extract_input_rows_from_prevout(tx)
    return if input_rows.empty?

    grouped_inputs = group_inputs_by_address(input_rows)
    return if grouped_inputs.size < 2

    @stats[:multi_input_txs] += 1

    ActiveRecord::Base.transaction do
      address_records = upsert_addresses!(grouped_inputs.keys, height)
      assign_input_stats!(address_records, grouped_inputs, height)
      cluster = attach_or_merge_clusters!(address_records)
      @stats[:links_created] += create_links!(address_records, txid, height)
      mark_cluster_dirty!(cluster)
    end

    @stats[:addresses_touched] += grouped_inputs.size
  rescue BitcoinRpc::Error => e
    @stats[:tx_skipped_rpc_errors] += 1
    puts "[cluster_scan] tx_skip txid=#{txid} height=#{height} reason=#{e.message}"
  rescue StandardError => e
    raise Error, "scan_transaction failed txid=#{txid} height=#{height}: #{e.class} - #{e.message}"
  end

  def extract_input_rows_from_prevout(tx)
    rows = []

    Array(tx["vin"]).each do |vin|
      next if vin["coinbase"].present?

      prevout = vin["prevout"]
      unless prevout.present?
        @stats[:tx_skipped_missing_prevout] += 1
        next
      end

      script_pub_key = prevout["scriptPubKey"] || {}
      address = extract_address(script_pub_key)
      next if address.blank?

      value_sats = btc_to_sats(prevout["value"])
      next if value_sats <= 0

      rows << {
        address: address,
        value_sats: value_sats
      }
    end

    rows
  end

  def group_inputs_by_address(rows)
    grouped = Hash.new(0)

    rows.each do |row|
      grouped[row[:address]] += row[:value_sats].to_i
    end

    grouped
  end

  def extract_address(script_pub_key)
    return if script_pub_key.blank?

    script_pub_key["address"].presence ||
      Array(script_pub_key["addresses"]).first.presence
  end

  def btc_to_sats(value)
    (value.to_d * 100_000_000).to_i
  rescue StandardError
    0
  end

  def coinbase_tx?(tx)
    Array(tx["vin"]).any? { |vin| vin["coinbase"].present? }
  end

  def upsert_addresses!(addresses, height)
    addresses.map do |addr|
      existing = Address.find_by(address: addr)
      next existing if existing.present?

      begin
        created = nil

        Address.transaction(requires_new: true) do
          created = Address.create!(
            address: addr,
            first_seen_height: height,
            last_seen_height: height
          )
        end

        created
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
        found = Address.find_by(address: addr)
        next found if found.present?

        raise Error, "upsert_address failed address=#{addr.inspect} height=#{height}: duplicate suspected but record not found"
      rescue => e
        raise Error, "upsert_address failed address=#{addr.inspect} height=#{height}: #{e.class} - #{e.message}"
      end
    end
  end

  def assign_input_stats!(address_records, grouped_inputs, height)
    address_records.each do |record|
      sent_sats = grouped_inputs.fetch(record.address, 0).to_i

      record.update!(
        first_seen_height: min_present(record.first_seen_height, height),
        last_seen_height: max_present(record.last_seen_height, height),
        total_sent_sats: record.total_sent_sats.to_i + sent_sats,
        tx_count: record.tx_count.to_i + 1
      )
    end
  end

  def attach_or_merge_clusters!(address_records)
    cluster_ids = address_records.map(&:cluster_id).compact.uniq

    if cluster_ids.empty?
      cluster = Cluster.create!

      Address.where(id: address_records.map(&:id)).update_all(
        cluster_id: cluster.id,
        updated_at: Time.current
      )

      @stats[:clusters_created] += 1
      return cluster
    end

    if cluster_ids.size == 1
      cluster = Cluster.find(cluster_ids.first)

      unclustered_ids = address_records.select { |record| record.cluster_id.nil? }.map(&:id)
      if unclustered_ids.any?
        Address.where(id: unclustered_ids).update_all(
          cluster_id: cluster.id,
          updated_at: Time.current
        )
      end

      return cluster
    end

    merge_clusters!(cluster_ids, address_records)
  end

  def merge_clusters!(cluster_ids, address_records)
    master_id = cluster_ids.min
    other_ids = cluster_ids - [master_id]

    Address.where(cluster_id: other_ids).update_all(
      cluster_id: master_id,
      updated_at: Time.current
    )

    unclustered_ids = address_records.select { |record| record.cluster_id.nil? }.map(&:id)
    if unclustered_ids.any?
      Address.where(id: unclustered_ids).update_all(
        cluster_id: master_id,
        updated_at: Time.current
      )
    end

    cleanup_derived_rows_for_clusters!([master_id] + other_ids)

    Cluster.where(id: other_ids).delete_all

    @stats[:clusters_merged] += other_ids.size

    Cluster.find(master_id)
  end

  def cleanup_derived_rows_for_clusters!(cluster_ids)
    ids = Array(cluster_ids).compact.uniq
    return if ids.empty?

    ClusterSignal.where(cluster_id: ids).delete_all
    ClusterMetric.where(cluster_id: ids).delete_all
    ClusterProfile.where(cluster_id: ids).delete_all
  end

  def create_links!(address_records, txid, height)
    records = address_records.sort_by(&:id)
    return 0 if records.size < 2

    pivot = records.first
    created = 0

    records.drop(1).each do |other|
      id_a, id_b = [pivot.id, other.id].sort

      link = AddressLink.find_or_initialize_by(
        address_a_id: id_a,
        address_b_id: id_b,
        link_type: "multi_input",
        txid: txid
      )

      next if link.persisted?

      link.block_height = height
      link.save!
      created += 1
    end

    created
  end

  def mark_cluster_dirty!(cluster)
    return if cluster.blank?

    @dirty_cluster_ids << cluster.id
  end

  def refresh_dirty_clusters!
    return if @dirty_cluster_ids.empty?

    puts "[cluster_scan] refresh_dirty_clusters count=#{@dirty_cluster_ids.size}"

    Cluster.where(id: @dirty_cluster_ids.to_a).find_each do |cluster|
      cluster.recalculate_stats!
      ClusterAggregator.call(cluster)
    end
  end

  def min_present(a, b)
    return b if a.blank?
    [a, b].min
  end

  def max_present(a, b)
    return b if a.blank?
    [a, b].max
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
end