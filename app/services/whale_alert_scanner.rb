# frozen_string_literal: true

# app/services/whale_alert_scanner.rb
class WhaleAlertScanner
  DEFAULT_VERBOSITY = 2 # getblock verbosity=2 => tx decoded

  def initialize(rpc: BitcoinRpc.new, logger: Rails.logger)
    @rpc    = rpc
    @logger = logger
  end

  # Scan les N derniers blocs (ex: 144)
  def scan_last_n_blocks!(n)
    tip  = @rpc.getblockcount.to_i
    from = [tip - n.to_i + 1, 0].max
    scan_range!(from_height: from, to_height: tip)
  end

  # Scan un intervalle [from..to]
  def scan_range!(from_height:, to_height:)
    (from_height.to_i..to_height.to_i).each do |height|
      scan_block!(height)
    end
  end

  # Scan un bloc (ignore coinbase)
  def scan_block!(height)
    block_hash = @rpc.getblockhash(height)
    block      = @rpc.getblock(block_hash, DEFAULT_VERBOSITY)
    block_time = Time.at(block.fetch("time")).utc

    txs = Array(block["tx"])
    txs.drop(1).each do |tx| # coinbase = tx[0]
      upsert_if_whale!(tx: tx, block_height: height, block_time: block_time)
    end
  rescue => e
    @logger.warn("[WhaleAlertScanner] scan_block height=#{height} failed: #{e.class} #{e.message}")
    raise
  end

  private

  # On calcule les métriques, on passe au classifier, puis on upsert
  def upsert_if_whale!(tx:, block_height:, block_time:)
    txid = tx.fetch("txid")

    # Optionnel (perf): si déjà en base, pas besoin de recalculer.
    return if WhaleAlert.exists?(txid: txid)

    vouts = Array(tx["vout"])

    # Ignore OP_RETURN / nulldata pour éviter de “polluer” certains patterns
    values = vouts.filter_map do |o|
      spk = o["scriptPubKey"] || {}
      next if spk["type"] == "nulldata"
      o["value"].to_d
    end

    total_out       = values.sum
    outputs_nonzero = values.count(&:positive?)
    largest         = values.max || 0.to_d
    ratio           = total_out.positive? ? (largest / total_out) : 0.to_d

    metrics = {
      total_out_btc: total_out,
      inputs_count: Array(tx["vin"]).size,
      outputs_count: vouts.size,
      outputs_nonzero_count: outputs_nonzero,
      largest_output_btc: largest
    }

    # Si tu as appliqué mon patch classifier:
    # classified = WhaleAlertClassifier.call(metrics, apply_threshold: true)
    classified = WhaleAlertClassifier.call(metrics)
    return unless classified

    now = Time.current

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

      alert_type: classified[:alert_type],
      score: classified[:score],
      exchange_likelihood: classified[:exchange_likelihood],
      exchange_hint: classified[:exchange_hint], # ✅ ajouté
      meta: (classified[:meta].is_a?(Hash) ? classified[:meta] : {}),

      updated_at: now
    }

    # created_at seulement si création (comme on a le guard exists?, c'est OK)
    attrs[:created_at] = now

    WhaleAlert.upsert(attrs, unique_by: :index_whale_alerts_on_txid)
  end
end
