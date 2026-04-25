# frozen_string_literal: true

# app/jobs/scan_whale_alerts_job.rb
#
# 🐋 ScanWhaleAlertsJob (improved)
# ===============================
# - Scanne des blocs Bitcoin via RPC (compatible pruned en passant blockhash)
# - Calcule des métriques simples + quelques signaux "cheap"
# - Filtre les tx whales sur largest_output_btc >= WHALE_MIN_BTC
# - Classifie via WhaleAlertClassifier
# - Upsert en batch via upsert_all (perf)
#
class ScanWhaleAlertsJob < ApplicationJob
  queue_as :default

  SCAN_VERSION       = "2026-03-03-v3"
  CLASSIFIER_VERSION = "2026-03-03-v3"

  WHALE_MIN_BTC = BigDecimal(ENV.fetch("WHALE_MIN_BTC", "100"))

  CONFIRMATIONS_SAFETY = Integer(ENV.fetch("WHALE_SCAN_CONFIRMATIONS_SAFETY", "2")) rescue 2
  UPSERT_BATCH_SIZE    = Integer(ENV.fetch("WHALE_UPSERT_BATCH_SIZE", "250")) rescue 250

  SMALL_OUTPUT_BTC = ENV.fetch("WHALE_SMALL_OUTPUT_BTC", "0.01").to_d
  DUST_LIKE_BTC    = ENV.fetch("WHALE_DUST_LIKE_BTC", "0.00001").to_d

  SKIP_IF_SAME_CLASSIFIER_VERSION = ENV.fetch("WHALE_SKIP_SAME_CLASSIFIER", "1") == "1"

  HEARTBEAT_EVERY_BLOCKS = Integer(ENV.fetch("WHALE_HEARTBEAT_EVERY_BLOCKS", "5")) rescue 5

  def perform(last_n_blocks: nil, from_height: nil, to_height: nil, job_run_id: nil)
    rpc = BitcoinRpc.new
    job_run = job_run_id.present? ? JobRun.find_by(id: job_run_id) : nil

    tip = rpc.get_blockchain_info["blocks"].to_i
    safe_tip = [0, tip - CONFIRMATIONS_SAFETY].max

    from, to =
      if from_height.present? && to_height.present?
        [from_height.to_i, to_height.to_i]
      else
        n = (last_n_blocks || 144).to_i
        n = 1 if n <= 0
        [[0, safe_tip - n + 1].max, safe_tip]
      end

    from = [0, from].max
    to   = [to, safe_tip].min

    total_blocks = [to - from + 1, 0].max
    scanned_blocks = 0

    update_progress!(
      job_run,
      pct: 0.0,
      label: "init #{from}..#{to}",
      meta: {
        from_height: from,
        to_height: to,
        tip: tip,
        safe_tip: safe_tip,
        total_blocks: total_blocks
      }
    )

    puts "🐋 [Whales] scanning blocks #{from}..#{to} (tip=#{tip}, safe_tip=#{safe_tip}, min_largest=#{WHALE_MIN_BTC.to_s('F')} BTC, scan_v=#{SCAN_VERSION}, clf_v=#{CLASSIFIER_VERSION})"

    (from..to).each do |height|
      scan_block!(rpc, height)
      scanned_blocks += 1

      if heartbeat_due?(scanned_blocks, total_blocks) || height == to
        pct =
          if total_blocks.positive?
            ((scanned_blocks.to_f / total_blocks) * 100).round(1)
          else
            100.0
          end

        update_progress!(
          job_run,
          pct: pct,
          label: "block #{height} / #{to}",
          meta: {
            from_height: from,
            current_height: height,
            to_height: to,
            scanned_blocks: scanned_blocks,
            total_blocks: total_blocks,
            tip: tip,
            safe_tip: safe_tip
          }
        )

        puts "🐋 [Whales] progress height=#{height} scanned=#{scanned_blocks}/#{total_blocks} pct=#{pct}%"
      end
    end

    update_progress!(
      job_run,
      pct: 100.0,
      label: "done #{from}..#{to}",
      meta: {
        from_height: from,
        to_height: to,
        scanned_blocks: scanned_blocks,
        total_blocks: total_blocks,
        tip: tip,
        safe_tip: safe_tip
      }
    )

    puts "✅ [Whales] scan done #{from}..#{to}"
  end

  private

  def heartbeat_due?(scanned_blocks, total_blocks)
    return true if scanned_blocks <= 1
    return true if total_blocks <= HEARTBEAT_EVERY_BLOCKS

    (scanned_blocks % HEARTBEAT_EVERY_BLOCKS).zero?
  end

  def update_progress!(job_run, pct:, label:, meta: {})
    return if job_run.blank?

    JobRunner.progress!(
      job_run,
      pct: pct,
      label: label,
      meta: meta
    )
  end

  def scan_block!(rpc, height)
    blockhash  = rpc.getblockhash(height)
    block      = rpc.getblock(blockhash, 2)
    block_time = Time.zone.at(block["time"].to_i)

    txs = Array(block["tx"])
    return if txs.empty?

    txids = txs.map { |tx| tx["txid"].to_s }.reject(&:blank?)

    existing_by_txid =
      WhaleAlert
        .where(txid: txids)
        .select(:txid, :meta, :created_at)
        .index_by(&:txid)

    rows = []
    now  = Time.current

    txs.each do |tx|
      txid = tx["txid"].to_s
      next if txid.blank?

      metrics = compute_metrics_for_tx(tx)
      next unless metrics
      next unless whale_tx?(metrics)

      existing = existing_by_txid[txid]

      if SKIP_IF_SAME_CLASSIFIER_VERSION && existing
        meta = existing.meta.is_a?(Hash) ? existing.meta : {}

        if meta["classifier_version"].to_s == CLASSIFIER_VERSION &&
           meta["scan_version"].to_s == SCAN_VERSION
          next
        end
      end

      classified = nil

      begin
        classified = WhaleAlertClassifier.call(metrics, apply_threshold: false)
      rescue
        classified = nil
      end

      if classified.nil?
        ratio_fallback =
          begin
            total = metrics[:total_out_btc].to_d

            if total.positive?
              (metrics[:largest_output_btc].to_d / total).round(4)
            else
              0.to_d
            end
          rescue
            0.to_d
          end

        classified = {
          alert_type: "other",
          score: 0,
          ratio: ratio_fallback,
          exchange_likelihood: 0,
          exchange_hint: "unlikely",
          flow_kind: "unknown",
          flow_confidence: 20,
          actor_band: nil,
          flow_reasons: [],
          flow_scores: {},
          meta: {}
        }
      end

      base_meta = classified[:meta].is_a?(Hash) ? classified[:meta] : {}

      base_meta = base_meta.merge(
        "classifier_version" => CLASSIFIER_VERSION,
        "scan_version" => SCAN_VERSION,
        "blockhash" => blockhash,
        "metrics" => {
          "second_largest_output_btc" => metrics[:second_largest_output_btc].to_s,
          "small_outputs_count" => metrics[:small_outputs_count],
          "dust_like_count" => metrics[:dust_like_count]
        }
      )

      flow_reasons_json = Array(classified[:flow_reasons]).to_json

      rows << {
        txid: txid,
        block_height: height,
        block_time: block_time,
        total_out_btc: metrics[:total_out_btc],
        inputs_count: metrics[:inputs_count],
        outputs_count: metrics[:outputs_count],
        outputs_nonzero_count: metrics[:outputs_nonzero_count],
        largest_output_btc: metrics[:largest_output_btc],
        largest_output_ratio: classified[:ratio],
        alert_type: classified[:alert_type],
        score: classified[:score],
        exchange_likelihood: classified[:exchange_likelihood],
        exchange_hint: classified[:exchange_hint],
        largest_output_address: metrics[:largest_output_address],
        largest_output_vout: metrics[:largest_output_vout],
        largest_output_desc: metrics[:largest_output_desc],
        tier: nil,
        flow_kind: classified[:flow_kind],
        flow_confidence: classified[:flow_confidence],
        actor_band: classified[:actor_band],
        flow_reasons: flow_reasons_json,
        flow_scores: classified[:flow_scores].is_a?(Hash) ? classified[:flow_scores] : {},
        meta: base_meta,
        created_at: existing ? existing.created_at : now,
        updated_at: now
      }

      if rows.size >= UPSERT_BATCH_SIZE
        upsert_rows!(rows)
        rows.clear
      end
    end

    upsert_rows!(rows) if rows.any?
  rescue BitcoinRpc::Error
    # bloc inaccessible -> skip
  end

  def upsert_rows!(rows)
    WhaleAlert.upsert_all(rows, unique_by: :index_whale_alerts_on_txid)
  end

  def compute_metrics_for_tx(tx)
    vout = Array(tx["vout"])
    return nil if vout.empty?

    nonzero = []
    vout.each do |o|
      val = BigDecimal(o["value"].to_s) rescue 0.to_d
      next unless val > 0
      nonzero << [o, val]
    end
    return nil if nonzero.empty?

    total = nonzero.sum { |_o, v| v }

    sorted = nonzero.sort_by { |_o, v| -v }
    max_o, max_v = sorted[0]
    second_v = sorted[1] ? sorted[1][1] : 0.to_d

    small_outputs_count = nonzero.count { |_o, v| v > 0 && v <= SMALL_OUTPUT_BTC }
    dust_like_count     = nonzero.count { |_o, v| v > 0 && v <= DUST_LIKE_BTC }

    spk = (max_o["scriptPubKey"] || {})

    addr =
      spk["address"] ||
      Array(spk["addresses"]).first

    asm_preview = spk["asm"].to_s
    asm_preview = asm_preview[0, 90] if asm_preview.length > 90
    desc = [spk["type"], asm_preview.presence].compact.join(" • ")

    {
      total_out_btc: total,
      largest_output_btc: max_v,
      second_largest_output_btc: second_v,
      inputs_count: Array(tx["vin"]).size,
      outputs_count: vout.size,
      outputs_nonzero_count: nonzero.size,
      small_outputs_count: small_outputs_count,
      dust_like_count: dust_like_count,
      largest_output_vout: max_o["n"],
      largest_output_address: addr,
      largest_output_desc: desc,
      timing_hint: nil
    }
  end

  def whale_tx?(metrics)
    BigDecimal(metrics[:largest_output_btc].to_s) >= WHALE_MIN_BTC
  end
end