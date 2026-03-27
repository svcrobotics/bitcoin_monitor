# frozen_string_literal: true

# app/services/whale_alert_scanner.rb
require "set"

class WhaleAlertScanner
  DEFAULT_VERBOSITY = 2 # getblock verbosity=2 => tx decoded

  # Progress logging
  DEFAULT_PROGRESS_EVERY = 10 # log toutes les 10 hauteurs
  MIN_PROGRESS_SECONDS   = 5  # ou toutes les 5s (évite spam si blocs rapides)

  # ---- Tiers (solution pro) ----
  # On collecte à partir de min_btc (ex: 100),
  # puis on classe chaque whale en tier :
  # - B (Mid)   : 100..299.999 BTC
  # - A (Large) : 300..999.999 BTC
  # - S (Mega)  : >= 1000 BTC
  #
  # Note: si tu changes les bornes, ne change qu’ici.
  TIER_B_MIN = 100.to_d
  TIER_A_MIN = 300.to_d
  TIER_S_MIN = 1000.to_d

  def initialize(rpc: BitcoinRpc.new, logger: Rails.logger, min_btc: nil)
    @rpc    = rpc
    @logger = logger

    # Seuil de collecte EXPLICITE (source de vérité côté scanner).
    # Si nil, on lit ENV au moment de l'init.
    @min_btc = (min_btc || ENV.fetch("WHALE_MIN_BTC", "100")).to_d
  end

  # Scan les N derniers blocs (ex: 144)
  def scan_last_n_blocks!(n)
    tip  = @rpc.getblockcount.to_i
    from = [tip - n.to_i + 1, 0].max
    scan_range!(from_height: from, to_height: tip)
  end

  # Scan un intervalle [from..to]
  def scan_range!(from_height:, to_height:)
    from  = from_height.to_i
    to    = to_height.to_i
    total = (to - from + 1)
    return if total <= 0

    progress_every = Integer(ENV.fetch("WHALE_PROGRESS_EVERY", DEFAULT_PROGRESS_EVERY.to_s)) rescue DEFAULT_PROGRESS_EVERY

    started  = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    last_log = started

    done       = 0
    tx_seen    = 0
    whales_new = 0

    # ---- stats tiers (pour debug/lecture) ----
    tier_counts = Hash.new(0) # {"B"=>12, "A"=>3, "S"=>1}

    plog("[WhaleAlertScanner] scan_range start from=#{from} to=#{to} total=#{total} min_btc=#{@min_btc}")

    (from..to).each do |height|
      res = scan_block!(height)

      done       += 1
      tx_seen    += res[:tx_seen]
      whales_new += res[:whales_new]

      # merge counts
      res[:tier_counts].each { |k, v| tier_counts[k] += v }

      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      should_log =
        (done == 1) ||
        (done == total) ||
        (progress_every.to_i.positive? && (done % progress_every).zero?) ||
        ((now - last_log) >= MIN_PROGRESS_SECONDS)

      if should_log
        pct     = (done.to_f / total * 100.0)
        elapsed = (now - started)
        rate    = elapsed / done
        eta     = (total - done) * rate

        plog(
          "[WhaleAlertScanner] progress #{done}/#{total} (#{format('%.1f', pct)}%) " \
          "height=#{height} tx=#{tx_seen} whales_new=#{whales_new} " \
          "tiers=#{tier_counts.inspect} elapsed=#{elapsed.round(1)}s eta≈#{eta.round}s"
        )
        last_log = now
      end
    end

    plog("[WhaleAlertScanner] scan_range done total=#{total} tx=#{tx_seen} whales_new=#{whales_new} tiers=#{tier_counts.inspect}")
  end

  # Scan un bloc (ignore coinbase)
  # Retourne des compteurs pour la progression
  def scan_block!(height)
    block_hash = @rpc.getblockhash(height)
    block      = @rpc.getblock(block_hash, DEFAULT_VERBOSITY)
    block_time = Time.at(block.fetch("time")).utc

    txs          = Array(block["tx"])
    non_coinbase = txs.drop(1)

    # Perf: éviter un SELECT exists? par tx → on charge les txids existants du bloc en 1 requête
    txids    = non_coinbase.map { |t| t["txid"] }.compact
    existing = txids.any? ? WhaleAlert.where(txid: txids).pluck(:txid).to_set : Set.new

    whales_new  = 0
    tier_counts = Hash.new(0)

    non_coinbase.each do |tx|
      txid = tx.fetch("txid")
      next if existing.include?(txid)

      res = upsert_if_whale!(tx: tx, block_height: height, block_time: block_time)
      if res[:upserted]
        whales_new += 1
        tier_counts[res[:tier]] += 1 if res[:tier].present?
      end
    end

    { tx_seen: [txs.size - 1, 0].max, whales_new: whales_new, tier_counts: tier_counts }
  rescue => e
    @logger.warn("[WhaleAlertScanner] scan_block height=#{height} failed: #{e.class} #{e.message}")
    raise
  end

  private

  # Log à la fois dans Rails logger ET sur STDOUT pour que le script bash voie la progression
  def plog(msg)
    @logger.info(msg)
    STDOUT.puts(msg)
  end

  def tier_for(total_out_btc)
    t = total_out_btc.to_d
    return nil if t <= 0
    return "S" if t >= TIER_S_MIN
    return "A" if t >= TIER_A_MIN
    return "B" if t >= TIER_B_MIN
    nil
  end

  # Retourne un hash :
  # - upserted: true/false
  # - tier: "B"/"A"/"S"/nil
  def upsert_if_whale!(tx:, block_height:, block_time:)
    vouts = Array(tx["vout"])

    # Ignore OP_RETURN / nulldata pour éviter de “polluer” certains patterns
    values = vouts.filter_map do |o|
      spk = o["scriptPubKey"] || {}
      next if spk["type"] == "nulldata"
      o["value"].to_d
    end

    total_out = values.sum
    return { upserted: false, tier: nil } if total_out < @min_btc # ✅ seuil explicite ici

    outputs_nonzero = values.count(&:positive?)
    largest         = values.max || 0.to_d
    ratio           = total_out.positive? ? (largest / total_out) : 0.to_d

    tier = tier_for(total_out)
    return { upserted: false, tier: nil } unless tier

    metrics = {
      total_out_btc: total_out,
      inputs_count: Array(tx["vin"]).size,
      outputs_count: vouts.size,
      outputs_nonzero_count: outputs_nonzero,
      largest_output_btc: largest,
      tier: tier
      # timing_hint: nil # hook prêt si tu veux plus tard
    }

    classified = WhaleAlertClassifier.call(metrics, apply_threshold: false) # seuil déjà appliqué ici
    return { upserted: false, tier: tier } unless classified

    now  = Time.current
    txid = tx.fetch("txid")

    # Meta: on conserve le meta du classifier, et on y ajoute notre "flow engine v2"
    meta_hash = (classified[:meta].is_a?(Hash) ? classified[:meta].dup : {})
    meta_hash["flow_engine_v2"] = {
      "flow_kind"       => classified[:flow_kind],
      "flow_confidence" => classified[:flow_confidence],
      "actor_band"      => classified[:actor_band],
      "flow_reasons"    => classified[:flow_reasons],
      "flow_scores"     => classified[:flow_scores]
    }.compact

    if ENV["WHALE_FLOW_DEBUG"] == "1"
      plog(
        "[WhaleFlow] txid=#{txid} total_out=#{total_out.to_s('F')} " \
        "type=#{classified[:alert_type]} flow=#{classified[:flow_kind]} " \
        "conf=#{classified[:flow_confidence]} band=#{classified[:actor_band]} " \
        "scores=#{classified[:flow_scores].inspect}"
      )
    end

    attrs = {
      txid: txid,
      block_height: block_height,
      block_time: block_time,

      total_out_btc: total_out,
      inputs_count: metrics[:inputs_count],
      outputs_count: metrics[:outputs_count],
      outputs_nonzero_count: metrics[:outputs_nonzero_count],
      largest_output_btc: largest,
      largest_output_ratio: ratio.round(4),

      tier: tier, # ✅ colonne dédiée

      alert_type: classified[:alert_type],
      score: classified[:score],
      exchange_likelihood: classified[:exchange_likelihood],
      exchange_hint: classified[:exchange_hint],
      meta: meta_hash,

      updated_at: now,
      created_at: now
    }

    WhaleAlert.upsert(attrs, unique_by: :index_whale_alerts_on_txid)
    { upserted: true, tier: tier }
  end
end
