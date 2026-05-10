# frozen_string_literal: true

require "bigdecimal"

class WhaleLayer1Scanner
  SCAN_VERSION = "2026-05-10-layer1-v1"
  CLASSIFIER_VERSION = "2026-03-03-v3"

  WHALE_MIN_BTC = BigDecimal(ENV.fetch("WHALE_MIN_BTC", "100"))
  UPSERT_BATCH_SIZE = Integer(ENV.fetch("WHALE_UPSERT_BATCH_SIZE", "250")) rescue 250

  SMALL_OUTPUT_BTC = ENV.fetch("WHALE_SMALL_OUTPUT_BTC", "0.01").to_d
  DUST_LIKE_BTC = ENV.fetch("WHALE_DUST_LIKE_BTC", "0.00001").to_d

  def self.call(last_n_blocks: nil, from_height: nil, to_height: nil, job_run: nil)
    new(
      last_n_blocks: last_n_blocks,
      from_height: from_height,
      to_height: to_height,
      job_run: job_run
    ).call
  end

  def initialize(last_n_blocks:, from_height:, to_height:, job_run:)
    @last_n_blocks = last_n_blocks.present? ? last_n_blocks.to_i : 144
    @from_height = from_height&.to_i
    @to_height = to_height&.to_i
    @job_run = job_run

    @stats = {
      scanned_blocks: 0,
      scanned_txs: 0,
      whale_txs: 0,
      upserted: 0,
      skipped_existing: 0
    }
  end

  def call
    best_height = layer1_best_height
    from, to = resolve_range(best_height)

    return empty_result(best_height, from, to) if from > to

    puts "[whale_layer1] start from=#{from} to=#{to} best_height=#{best_height} min_btc=#{WHALE_MIN_BTC.to_s('F')}"

    rows = []

    (from..to).each_with_index do |height, index|
      scan_height(height, rows)

      flush_rows!(rows) if rows.size >= UPSERT_BATCH_SIZE

      update_progress!(
        current: index + 1,
        total: to - from + 1,
        height: height,
        from: from,
        to: to,
        best_height: best_height
      )
    end

    flush_rows!(rows)

    {
      ok: true,
      source: "layer1",
      from_height: from,
      to_height: to,
      best_height: best_height
    }.merge(@stats)
  end

  private

  def layer1_best_height
    BlockBufferModel.where(status: "processed").maximum(:height).to_i
  end

  def resolve_range(best_height)
    if @from_height.present? && @to_height.present?
      return [[0, @from_height].max, [@to_height, best_height].min]
    end

    n = [@last_n_blocks.to_i, 1].max
    [[0, best_height - n + 1].max, best_height]
  end

  def empty_result(best_height, from, to)
    {
      ok: true,
      source: "layer1",
      note: "nothing to scan",
      best_height: best_height,
      from_height: from,
      to_height: to
    }
  end

  def scan_height(height, rows)
    outputs = TxOutput.where(block_height: height)
    txids = outputs.distinct.pluck(:txid)

    @stats[:scanned_blocks] += 1
    @stats[:scanned_txs] += txids.size

    existing_txids =
      WhaleAlert
        .where(txid: txids)
        .pluck(:txid)
        .to_set

    txids.each do |txid|
      if existing_txids.include?(txid)
        @stats[:skipped_existing] += 1
        next
      end

      metrics = metrics_for_txid(txid, height)
      next if metrics.blank?
      next if metrics[:total_out_btc].to_d < WHALE_MIN_BTC

      classified = WhaleAlertClassifier.call(metrics, apply_threshold: false)
      next if classified.blank?

      rows << build_row(metrics, classified)

      @stats[:whale_txs] += 1
    end
  end

  def metrics_for_txid(txid, height)
    outputs =
      TxOutput
        .where(txid: txid, block_height: height)
        .where.not(amount_btc: nil)
        .to_a

    return nil if outputs.empty?

    values = outputs.map { |o| o.amount_btc.to_d }.select(&:positive?)
    return nil if values.empty?

    total_out = values.sum
    largest_output = outputs.max_by { |o| o.amount_btc.to_d }
    return nil if largest_output.blank?

    nonzero_count = values.size

    {
      txid: txid,
      block_height: height,
      block_time: largest_output.block_time,
      block_hash: largest_output.block_hash,

      total_out_btc: total_out,
      inputs_count: input_count_for_txid(txid),
      outputs_count: outputs.size,
      outputs_nonzero_count: nonzero_count,

      largest_output_btc: largest_output.amount_btc.to_d,
      largest_output_address: largest_output.address,
      largest_output_vout: largest_output.vout,
      largest_output_desc: nil,

      second_largest_output_btc: second_largest(values),
      small_outputs_count: values.count { |v| v < SMALL_OUTPUT_BTC },
      dust_like_count: values.count { |v| v < DUST_LIKE_BTC }
    }
  end

  def input_count_for_txid(txid)
    TxOutput.where(spent_txid: txid).count
  end

  def second_largest(values)
    values.sort.reverse[1] || 0.to_d
  end

  def build_row(metrics, classified)
    now = Time.current

    base_meta = classified[:meta].is_a?(Hash) ? classified[:meta] : {}

    meta = base_meta.merge(
      "classifier_version" => CLASSIFIER_VERSION,
      "scan_version" => SCAN_VERSION,
      "blockhash" => metrics[:block_hash],
      "source" => "layer1",
      "metrics" => {
        "second_largest_output_btc" => metrics[:second_largest_output_btc].to_s,
        "small_outputs_count" => metrics[:small_outputs_count],
        "dust_like_count" => metrics[:dust_like_count]
      }
    )

    {
      txid: metrics[:txid],
      block_height: metrics[:block_height],
      block_time: metrics[:block_time],

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

      tier: tier_for(metrics[:total_out_btc]),
      flow_kind: classified[:flow_kind],
      flow_confidence: classified[:flow_confidence],
      actor_band: classified[:actor_band],
      flow_reasons: Array(classified[:flow_reasons]).to_json,
      flow_scores: classified[:flow_scores].is_a?(Hash) ? classified[:flow_scores] : {},

      meta: meta,
      created_at: now,
      updated_at: now
    }
  end

  def tier_for(total_out_btc)
    value = total_out_btc.to_d

    return "S" if value >= 1000
    return "A" if value >= 300
    return "B" if value >= 100

    nil
  end

  def flush_rows!(rows)
    return if rows.empty?

    WhaleAlert.upsert_all(
      rows,
      unique_by: :index_whale_alerts_on_txid
    )

    @stats[:upserted] += rows.size
    rows.clear
  end

  def update_progress!(current:, total:, height:, from:, to:, best_height:)
    return if @job_run.blank?
    return unless (current % 5).zero? || current == total

    pct = ((current.to_f / total.to_f) * 100).round(1)

    JobRunner.progress!(
      @job_run,
      pct: pct,
      label: "block #{height} / #{to}",
      meta: @stats.merge(
        from_height: from,
        current_height: height,
        to_height: to,
        best_height: best_height,
        source: "layer1"
      )
    )
  end
end
