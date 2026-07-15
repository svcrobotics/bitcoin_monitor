# frozen_string_literal: true

require "set"

class ClusterScanner
  class Error < StandardError; end

  SATS_PER_BTC = 100_000_000

  def self.call(**arguments)
    new(**arguments).call
  end

  def initialize(
    height: nil,
    from_height: nil,
    to_height: nil,
    limit: nil,
    mode: :batch,
    refresh: false,
    **_unused
  )
    @height = height&.to_i
    @from_height = from_height&.to_i
    @to_height = to_height&.to_i
    @limit = limit&.to_i
    @mode = mode.to_sym
    @refresh = refresh
    @stats = default_stats
    @changed_cluster_ids = Set.new
  end

  def call
    raise ArgumentError, "ClusterScanner requires an explicit height range" unless explicit_range?
    raise ArgumentError, "ClusterScanner cannot publish refresh work" if @refresh

    heights = requested_heights
    heights.each { |height| scan_block(height) }

    build_result(heights)
  end

  private

  def explicit_range?
    @height || (@from_height && @to_height)
  end

  def requested_heights
    first = @height || @from_height
    last = @height || @to_height
    raise ArgumentError, "invalid ClusterScanner height range" if first.negative? || last < first

    last = [last, first + @limit - 1].min if @limit&.positive?
    (first..last).to_a
  end

  def scan_block(height)
    ApplicationRecord.transaction do
      txids = layer1_spending_txids_for_height(height)
      inputs_by_txid = layer1_inputs_for_txids(txids, height: height)

      txids.each do |txid|
        @stats[:scanned_txs] += 1
        scan_transaction(
          txid: txid,
          height: height,
          input_rows: inputs_by_txid.fetch(txid, [])
        )
      end
    end

    @stats[:scanned_blocks] += 1
  rescue StandardError => error
    raise Error,
      "scan_block failed height=#{height}: #{error.class} - #{error.message}"
  end

  def scan_transaction(txid:, height:, input_rows:)
    return if input_rows.size < 2

    @stats[:multi_input_candidates] += 1
    grouped = grouped_layer1_inputs(input_rows)
    return if grouped.size < 2

    if @mode == :realtime
      maximum = Integer(ENV.fetch("CLUSTER_REALTIME_MAX_GROUPED_ADDRESSES", "50"))
      minimum = Integer(ENV.fetch("CLUSTER_REALTIME_MIN_GROUPED_ADDRESSES", "3"))

      if grouped.size > maximum
        @stats[:tx_skipped_too_large] += 1
        return
      end
      if grouped.size < minimum
        @stats[:tx_skipped_too_small] += 1
        return
      end
    end

    @stats[:multi_address_candidates] += 1
    @stats[:multi_input_txs] += 1
    @stats[:input_rows_found] += grouped.sum { |input| input[:total_inputs] }

    address_records, created_count = write_addresses(grouped, height: height)
    versions_before = cluster_versions(address_records.filter_map(&:cluster_id))
    merge_result = Clusters::ClusterMerger.call(address_records: address_records)
    links_created = write_links(
      address_records: address_records,
      txid: txid,
      height: height
    )

    record_changed_clusters(merge_result, versions_before: versions_before)
    @stats[:addresses_created] += created_count
    @stats[:addresses_touched] += grouped.size
    @stats[:links_created] += links_created
    @stats[:clusters_created] += merge_result.created.to_i
    @stats[:clusters_merged] += merge_result.merged.to_i
  rescue StandardError => error
    raise Error,
      "scan_transaction failed txid=#{txid} height=#{height}: " \
      "#{error.class} - #{error.message}"
  end

  def write_addresses(grouped, height:)
    addresses = grouped.map { |input| input[:address] }.uniq.sort
    existing = Address.where(address: addresses).pluck(:address).to_set
    now = Time.current
    rows = addresses.map do |address|
      {
        address: address,
        first_seen_height: height,
        last_seen_height: height,
        total_sent_sats: 0,
        tx_count: 0,
        created_at: now,
        updated_at: now
      }
    end

    Address.upsert_all(
      rows,
      unique_by: :index_addresses_on_address,
      on_duplicate: Arel.sql(
        "first_seen_height = LEAST(addresses.first_seen_height, EXCLUDED.first_seen_height), " \
        "last_seen_height = GREATEST(addresses.last_seen_height, EXCLUDED.last_seen_height), " \
        "updated_at = EXCLUDED.updated_at"
      )
    )

    [Address.where(address: addresses).order(:id).to_a, addresses.count { |address| !existing.include?(address) }]
  end

  def write_links(address_records:, txid:, height:)
    sorted = address_records.sort_by(&:id)
    return 0 if sorted.size < 2

    now = Time.current
    pivot = sorted.first
    rows = sorted.drop(1).map do |other|
      first, second = [pivot.id, other.id].sort
      {
        address_a_id: first,
        address_b_id: second,
        link_type: "multi_input",
        txid: txid,
        block_height: height,
        created_at: now,
        updated_at: now
      }
    end

    AddressLink.insert_all(
      rows,
      unique_by: :idx_address_links_uniqueness,
      returning: [:id]
    ).rows.size
  end

  def record_changed_clusters(result, versions_before:)
    versions_after = result.composition_versions.transform_keys(&:to_i)
    changed = versions_after.each_key.select do |cluster_id|
      versions_before[cluster_id] != versions_after[cluster_id]
    end
    changed |= Array(result.source_cluster_ids).map(&:to_i) if result.merged.to_i.positive?
    changed << result.target_cluster_id.to_i if result.created.to_i.positive? || result.merged.to_i.positive?
    @changed_cluster_ids.merge(changed.reject(&:zero?))
  end

  def cluster_versions(cluster_ids)
    Cluster.where(id: cluster_ids).pluck(:id, :composition_version).to_h
  end

  def layer1_spending_txids_for_height(height)
    ClusterInput
      .where(spent_block_height: height)
      .where.not(spent_txid: [nil, ""])
      .group(:spent_txid)
      .having("COUNT(*) >= ?", Integer(ENV.fetch("CLUSTER_MIN_INPUTS_PER_TX", "2")))
      .order(:spent_txid)
      .pluck(:spent_txid)
  end

  def layer1_inputs_for_txids(txids, height:)
    grouped = Hash.new { |hash, key| hash[key] = [] }
    ClusterInput
      .where(spent_txid: txids, spent_block_height: height)
      .where.not(address: [nil, ""])
      .where.not(amount_btc: nil)
      .order(:spent_txid, :id)
      .pluck(:spent_txid, :address, :amount_btc)
      .each do |spent_txid, address, amount_btc|
        grouped[spent_txid] << {
          address: address,
          value_sats: btc_to_sats(amount_btc)
        }
      end
    grouped
  end

  def grouped_layer1_inputs(input_rows)
    input_rows
      .group_by { |row| row[:address] }
      .sort_by(&:first)
      .map do |address, rows|
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

  def build_result(heights)
    clusters_touched =
      Cluster
        .where(id: @changed_cluster_ids.to_a)
        .order(:id)
        .pluck(:id, :composition_version)
        .map do |cluster_id, composition_version|
          {
            cluster_id: cluster_id,
            composition_version: composition_version
          }
        end

    {
      ok: true,
      height: heights.one? ? heights.first : nil,
      heights: heights,
      start_height: heights.first,
      end_height: heights.last,
      clusters_touched: clusters_touched,
      clusters_touched_count: clusters_touched.size
    }.merge(@stats)
  end

  def default_stats
    {
      scanned_blocks: 0,
      scanned_txs: 0,
      multi_input_txs: 0,
      input_rows_found: 0,
      addresses_created: 0,
      addresses_touched: 0,
      links_created: 0,
      clusters_created: 0,
      clusters_merged: 0,
      multi_input_candidates: 0,
      multi_address_candidates: 0,
      tx_skipped_too_large: 0,
      tx_skipped_too_small: 0
    }
  end
end
