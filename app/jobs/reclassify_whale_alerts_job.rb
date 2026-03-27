# frozen_string_literal: true

# app/jobs/reclassify_whale_alerts_job.rb
#
# 🔁 ReclassifyWhaleAlertsJob
# ==========================
# Recalcule alert_type/score/flow_kind/exchange_hint/etc à partir des données déjà en base,
# sans RPC (super rapide). Idéal après modification des règles du WhaleAlertClassifier.
#
class ReclassifyWhaleAlertsJob < ApplicationJob
  queue_as :low

  RECLASS_VERSION = "2026-03-03-v1"
  BATCH_SIZE = Integer(ENV.fetch("WHALE_RECLASSIFY_BATCH_SIZE", "500")) rescue 500

  def perform(days_back: 7, from_height: nil, to_height: nil, since_time: nil)
    scope =
      if since_time.present?
        WhaleAlert.where("block_time >= ?", since_time)
      elsif from_height.present? && to_height.present?
        WhaleAlert.where(block_height: from_height.to_i..to_height.to_i)
      else
        WhaleAlert.where("block_time >= ?", days_back.to_i.days.ago)
      end

    total = scope.count
    puts "🔁 [WhalesReclass] start count=#{total} batch=#{BATCH_SIZE} reclass_v=#{RECLASS_VERSION}"

    now = Time.current
    processed = 0
    updated   = 0

    scope.in_batches(of: BATCH_SIZE) do |batch_rel|
      batch = batch_rel.to_a
      processed += batch.size

      updates = []
      batch.each do |a|
        metrics = {
          total_out_btc: a.total_out_btc,
          inputs_count: a.inputs_count,
          outputs_count: a.outputs_count,
          outputs_nonzero_count: a.outputs_nonzero_count,
          largest_output_btc: a.largest_output_btc,
          timing_hint: (a.meta.is_a?(Hash) ? a.meta["timing_hint"] : nil)
        }

        c = WhaleAlertClassifier.call(metrics, apply_threshold: false)
        next unless c

        meta_in = a.meta.is_a?(Hash) ? a.meta : {}
        meta_out =
          meta_in
            .merge(c[:meta].is_a?(Hash) ? c[:meta] : {})
            .merge(
              "reclass_version" => RECLASS_VERSION,
              "reclass_at"      => now.iso8601
            )

        updates << {
          txid: a.txid,

          alert_type: c[:alert_type],
          score: c[:score],
          largest_output_ratio: c[:ratio],

          exchange_likelihood: c[:exchange_likelihood],
          exchange_hint: c[:exchange_hint],

          flow_kind: c[:flow_kind],
          flow_confidence: c[:flow_confidence],
          actor_band: c[:actor_band],

          flow_reasons: Array(c[:flow_reasons]).to_json,
          flow_scores: (c[:flow_scores].is_a?(Hash) ? c[:flow_scores] : {}),

          meta: meta_out,
          updated_at: now
        }
      end

      if updates.any?
        WhaleAlert.upsert_all(updates, unique_by: :index_whale_alerts_on_txid)
        updated += updates.size
      end

      puts "🔁 [WhalesReclass] progress processed=#{processed}/#{total} updated=#{updated}"
    end

    puts "✅ [WhalesReclass] done processed=#{processed} updated=#{updated} reclass_v=#{RECLASS_VERSION}"
  end
end