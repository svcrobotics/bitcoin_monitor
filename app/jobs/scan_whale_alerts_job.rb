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

  # --- Versions (pour reclasser proprement quand tu changes les règles) ---
  SCAN_VERSION       = "2026-03-03-v3"
  CLASSIFIER_VERSION = "2026-03-03-v3"

  # --- Paramètres ---
  # Filtre principal (whale) : plus gros output
  WHALE_MIN_BTC = BigDecimal(ENV.fetch("WHALE_MIN_BTC", "100"))

  # Évite les micro reorgs : scan seulement jusqu'à tip - CONFIRMATIONS_SAFETY (default 2)
  CONFIRMATIONS_SAFETY = Integer(ENV.fetch("WHALE_SCAN_CONFIRMATIONS_SAFETY", "2")) rescue 2

  # Batch DB
  UPSERT_BATCH_SIZE = Integer(ENV.fetch("WHALE_UPSERT_BATCH_SIZE", "250")) rescue 250

  # Seuils "cheap" pour signaux additionnels (sans lookup UTXO)
  SMALL_OUTPUT_BTC = ENV.fetch("WHALE_SMALL_OUTPUT_BTC", "0.01").to_d
  DUST_LIKE_BTC    = ENV.fetch("WHALE_DUST_LIKE_BTC", "0.00001").to_d # ~1k sats

  # Si true : si un txid existe déjà et meta.classifier_version identique -> skip classification (gain perf)
  SKIP_IF_SAME_CLASSIFIER_VERSION = ENV.fetch("WHALE_SKIP_SAME_CLASSIFIER", "1") == "1"

  def perform(last_n_blocks: nil, from_height: nil, to_height: nil)
    rpc = BitcoinRpc.new

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

    puts "🐋 [Whales] scanning blocks #{from}..#{to} (tip=#{tip}, safe_tip=#{safe_tip}, min_largest=#{WHALE_MIN_BTC.to_s('F')} BTC, scan_v=#{SCAN_VERSION}, clf_v=#{CLASSIFIER_VERSION})"

    (from..to).each do |height|
      scan_block!(rpc, height)
    end

    puts "✅ [Whales] scan done #{from}..#{to}"
  end

  private

  def scan_block!(rpc, height)
    blockhash  = rpc.getblockhash(height)
    block      = rpc.getblock(blockhash)
    block_time = Time.zone.at(block["time"].to_i)

    txids = Array(block["tx"])
    return if txids.empty?

    # --- Prefetch existants pour éviter N queries ---
    existing_by_txid = WhaleAlert.where(txid: txids).select(:txid, :meta, :created_at).index_by(&:txid)

    rows = []
    now  = Time.current

    txids.each do |txid|
      tx =
        begin
          rpc.getrawtransaction(txid, true, blockhash)
        rescue BitcoinRpc::Error
          next
        end

      metrics = compute_metrics_for_tx(tx)
      next unless metrics
      next unless whale_tx?(metrics)

      # Option perf: skip si déjà classifié avec même version
      existing = existing_by_txid[txid]
      if SKIP_IF_SAME_CLASSIFIER_VERSION && existing
        meta = existing.meta.is_a?(Hash) ? existing.meta : {}
        if meta["classifier_version"].to_s == CLASSIFIER_VERSION && meta["scan_version"].to_s == SCAN_VERSION
          # On met quand même à jour block_height/time si tu rescannes (mais en pratique identique)
          # => ici on skip totalement pour perf.
          next
        end
      end

      # Classification
      classified = nil
      begin
        # Le job filtre déjà via WHALE_MIN_BTC (largest_output), donc pas de seuil côté classifier
        classified = WhaleAlertClassifier.call(metrics, apply_threshold: false)
      rescue => _e
        classified = nil
      end

      # Fallbacks si classifier nil
      if classified.nil?
        ratio_fallback =
          begin
            tot = metrics[:total_out_btc].to_d
            tot.positive? ? (metrics[:largest_output_btc].to_d / tot).round(4) : 0.to_d
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
      
      # Meta enrichie
      base_meta = classified[:meta].is_a?(Hash) ? classified[:meta] : {}
      base_meta = base_meta.merge(
        "classifier_version" => CLASSIFIER_VERSION,
        "scan_version"       => SCAN_VERSION,
        "blockhash"          => blockhash,
        "metrics" => {
          "second_largest_output_btc" => metrics[:second_largest_output_btc].to_s,
          "small_outputs_count"       => metrics[:small_outputs_count],
          "dust_like_count"           => metrics[:dust_like_count]
        }
      )

      # IMPORTANT: flow_reasons est text chez toi => on stocke JSON string stable
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

        # ✅ colonnes que tu as mais qui étaient vides
        largest_output_address: metrics[:largest_output_address],
        largest_output_vout: metrics[:largest_output_vout],
        largest_output_desc: metrics[:largest_output_desc],

        # tier (optionnel: tu peux l'utiliser si tu veux. Ici on le laisse nil)
        tier: nil,

        # Nouveaux champs déjà dans ton schema
        flow_kind: classified[:flow_kind],
        flow_confidence: classified[:flow_confidence],
        actor_band: classified[:actor_band],

        flow_reasons: flow_reasons_json,
        flow_scores: (classified[:flow_scores].is_a?(Hash) ? classified[:flow_scores] : {}),

        meta: base_meta,

        created_at: (existing ? existing.created_at : now),
        updated_at: now
      }

      # flush batch
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
    # Rails: upsert_all nécessite unique_by : index unique txid
    WhaleAlert.upsert_all(rows, unique_by: :index_whale_alerts_on_txid)
  end

  # Métriques + extraction du plus gros output + signaux cheap
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

    # max + second max
    sorted = nonzero.sort_by { |_o, v| -v }
    max_o, max_v = sorted[0]
    second_v = sorted[1] ? sorted[1][1] : 0.to_d

    # signaux "cheap"
    small_outputs_count = nonzero.count { |_o, v| v > 0 && v <= SMALL_OUTPUT_BTC }
    dust_like_count     = nonzero.count { |_o, v| v > 0 && v <= DUST_LIKE_BTC }

    # extract addr/vout/desc du plus gros output
    spk = (max_o["scriptPubKey"] || {})

    addr =
      spk["address"] ||
      Array(spk["addresses"]).first

    # desc courte : type + preview asm
    asm_preview = spk["asm"].to_s
    asm_preview = asm_preview[0, 90] if asm_preview.length > 90
    desc = [spk["type"], (asm_preview.presence)].compact.join(" • ")

    # timing_hint : prêt pour toi (tu pourras le passer depuis un autre builder)
    # Ici nil car le scan n'a pas encore ce contexte.
    timing_hint = nil

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

      timing_hint: timing_hint
    }
  end

  def whale_tx?(metrics)
    BigDecimal(metrics[:largest_output_btc].to_s) >= WHALE_MIN_BTC
  end
end