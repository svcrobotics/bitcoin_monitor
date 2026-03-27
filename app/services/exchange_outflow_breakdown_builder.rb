# frozen_string_literal: true

# Build breakdown of outflow "where it goes" (Level 2):
# - Use ExchangeObservedUtxo.spent_by_txid as the set of tx spending observed exchange UTXOs for a day.
# - For each tx, parse outputs (vout) via bitcoind RPC.
# - Classify each output as internal (back to exchange-like address set) vs external (everything else).
# - Aggregate by script type buckets (p2tr/p2wpkh/...) and write rows into exchange_outflow_breakdowns.
#
# Works in pruned mode, but may have missing txs (no txindex). We store coverage in meta.
class ExchangeOutflowBreakdownBuilder
  class Error < StandardError; end

  # Conservative: if too many tx are missing, we still write what we have
  # but record coverage. You can choose to skip below a threshold if you want.
  MIN_COVERAGE_PCT = ENV.fetch("OUTFLOW_BREAKDOWN_MIN_COVERAGE_PCT", "30").to_f

  # Exchange-like min occurrences (reuse your setting)
  MIN_OCC = Integer(ENV.fetch("EXCHANGE_ADDR_MIN_OCC", "8")) rescue 8

  BUCKETS = %w[p2tr p2wpkh p2wsh p2sh p2pkh op_return unknown].freeze

  SCRIPT_TYPE_TO_BUCKET = {
    "witness_v1_taproot"     => "p2tr",
    "witness_v0_keyhash"     => "p2wpkh",
    "witness_v0_scripthash"  => "p2wsh",
    "scripthash"             => "p2sh",
    "pubkeyhash"             => "p2pkh",
    "nulldata"               => "op_return"
  }.freeze

  def self.call(day:, rpc: nil, write_internal: false, write_gross: false)
    new(day: day, rpc: rpc, write_internal: write_internal, write_gross: write_gross).call
  end

  def initialize(day:, rpc:, write_internal:, write_gross:)
    @day = day.to_date
    @rpc = rpc || BitcoinRpc.new(wallet: nil) # chain endpoint only
    @write_internal = !!write_internal
    @write_gross = !!write_gross
  end

  def call
    txids = ExchangeObservedUtxo
      .where(spent_day: @day)
      .where.not(spent_by_txid: nil)
      .distinct
      .pluck(:spent_by_txid)

    # If nothing, still clear old rows (optional) and exit
    if txids.empty?
      delete_existing!
      return { ok: true, day: @day, txids: 0, note: "no spent_by_txid for day" }
    end

    exchange_addr_set = load_exchange_like_addresses_set

    sums_ext = empty_sums
    sums_int = empty_sums
    sums_gross = empty_sums

    total_tx = txids.size
    ok_tx = 0
    missing_tx = 0
    total_outputs = 0

    txids.each do |txid|
      tx = fetch_tx_verbose(txid)
      if tx.nil?
        missing_tx += 1
        next
      end

      ok_tx += 1
      vouts = Array(tx["vout"])
      total_outputs += vouts.size

      vouts.each do |vout|
        val = vout["value"]
        next if val.nil?
        btc = val.to_d
        next if btc <= 0

        spk = vout["scriptPubKey"] || {}
        bucket = bucket_for(spk)
        bucket = "unknown" unless BUCKETS.include?(bucket)

        addr = extract_address(spk)
        is_exchange_like = addr.present? && exchange_addr_set.include?(addr)

        sums_gross[bucket] += btc
        if is_exchange_like
          sums_int[bucket] += btc
        else
          sums_ext[bucket] += btc
        end
      end
    end

    coverage_pct = (total_tx > 0 ? (ok_tx.to_f / total_tx.to_f * 100.0) : 0.0)
    meta_base = {
      "day" => @day.to_s,
      "min_occ" => MIN_OCC,
      "tx_total" => total_tx,
      "tx_ok" => ok_tx,
      "tx_missing" => missing_tx,
      "outputs_total" => total_outputs,
      "coverage_pct" => coverage_pct.round(2),
      "mode" => "level2_by_script_type",
      "note" => "external = outputs to non-exchange-like addresses; internal = outputs back to exchange-like set"
    }

    delete_existing!

    # Optional guard: if coverage is terrible, you might prefer to skip writing
    # Here we still write, but you can choose to early return.
    # return { ok: false, day: @day, coverage_pct: coverage_pct, note: "coverage below threshold" } if coverage_pct < MIN_COVERAGE_PCT

    upsert_scope!("external", sums_ext, meta_base)

    if @write_internal
      upsert_scope!("internal", sums_int, meta_base)
    end

    if @write_gross
      upsert_scope!("gross", sums_gross, meta_base)
    end

    { ok: true, day: @day, tx_total: total_tx, tx_ok: ok_tx, coverage_pct: coverage_pct.round(2) }
  end

  private

  def empty_sums
    BUCKETS.index_with { 0.to_d }
  end

  def delete_existing!
    ExchangeOutflowBreakdown.where(day: @day).delete_all
  end

  def upsert_scope!(scope, sums, meta_base)
    total = sums.values.sum
    computed_at = Time.current

    rows =
      BUCKETS.map do |bucket|
        btc = sums[bucket].to_d
        pct = total.positive? ? (btc / total * 100.0) : nil

        {
          day: @day,
          scope: scope,
          bucket: bucket,
          btc: btc,
          pct: pct,
          meta: meta_base.merge(
            "scope_total_btc" => total.to_s,
            "scope" => scope
          ),
          computed_at: computed_at,
          created_at: computed_at,
          updated_at: computed_at
        }
      end

    ExchangeOutflowBreakdown.upsert_all(
      rows,
      unique_by: :idx_outflow_breakdowns_unique
    )
  end

  def load_exchange_like_addresses_set
    # We only need addresses, cache them in memory for speed
    ExchangeAddress
      .where("occurrences >= ?", MIN_OCC)
      .where.not(address: [nil, ""])
      .pluck(:address)
      .to_set
  end

  def fetch_tx_verbose(txid)
    # We try to get blockhash from one observed UTXO row
    row = ExchangeObservedUtxo
            .where(spent_day: @day, spent_by_txid: txid)
            .where.not(spent_blockhash: nil)
            .first

    return nil unless row&.spent_blockhash

    @rpc.getrawtransaction(txid, true, row.spent_blockhash)
  rescue BitcoinRpc::Error
    nil
  rescue => _
    nil
  end

  def bucket_for(script_pubkey)
    t = script_pubkey["type"].to_s
    SCRIPT_TYPE_TO_BUCKET[t] || "unknown"
  end

  def extract_address(script_pubkey)
    # bitcoind verbose can expose:
    # - "address" (newer)
    # - "addresses" (older / multisig-ish)
    a = script_pubkey["address"].presence
    return a if a.present?

    arr = script_pubkey["addresses"]
    return arr.first.to_s if arr.is_a?(Array) && arr.first.present?

    nil
  end
end