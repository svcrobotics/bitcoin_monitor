# frozen_string_literal: true

class WhaleAlertScanner
  def initialize(rpc: BitcoinRpc.new)
    @rpc = rpc
  end

  def scan_last_n_blocks!(n)
    tip  = @rpc.getblockcount.to_i
    from = [tip - n + 1, 0].max
    scan_range!(from_height: from, to_height: tip)
  end

  def scan_range!(from_height:, to_height:)
    (from_height..to_height).each do |height|
      scan_block!(height)
    end
  end

  def scan_block!(height)
    block_hash = @rpc.getblockhash(height)
    block      = @rpc.getblock(block_hash, 2)
    block_time = Time.at(block.fetch("time")).utc

    block.fetch("tx").drop(1).each do |tx| # ignore coinbase
      upsert_if_whale!(tx:, block_height: height, block_time:)
    end
  end

  private

  def upsert_if_whale!(tx:, block_height:, block_time:)
    txid = tx.fetch("txid")
    return if WhaleAlert.exists?(txid:) # optionnel

    vouts = tx.fetch("vout")

    values = vouts.filter_map do |o|
      spk = o["scriptPubKey"] || {}
      next if spk["type"] == "nulldata"
      o["value"].to_d
    end

    total_out = values.sum
    outputs_nonzero = values.count(&:positive?)
    largest = values.max || 0.to_d
    ratio   = total_out.positive? ? (largest / total_out) : 0.to_d

    metrics = {
      total_out_btc: total_out,
      inputs_count: tx.fetch("vin").size,
      outputs_count: vouts.size,
      outputs_nonzero_count: outputs_nonzero,
      largest_output_btc: largest
    }

    classified = WhaleAlertClassifier.call(metrics)
    return unless classified

    WhaleAlert.upsert(
      {
        txid:,
        block_height:,
        block_time:,
        total_out_btc: total_out,
        inputs_count: metrics[:inputs_count],
        outputs_count: metrics[:outputs_count],
        outputs_nonzero_count: metrics[:outputs_nonzero_count],
        largest_output_btc: largest,
        largest_output_ratio: ratio,
        alert_type: classified[:alert_type],
        score: classified[:score],
        meta: classified[:meta],
        updated_at: Time.current,
        created_at: Time.current
      },
      unique_by: :index_whale_alerts_on_txid
    )
  end
end
