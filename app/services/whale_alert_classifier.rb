# frozen_string_literal: true

# app/services/whale_alert_classifier.rb
class WhaleAlertClassifier
  DEFAULT_MIN_BTC = "100"

  # Seuil global (ENV)
  def self.min_btc
    ENV.fetch("WHALE_MIN_BTC", DEFAULT_MIN_BTC).to_d
  end

  # Metrics attendues (keys):
  # - :total_out_btc (BigDecimal/num)
  # - :inputs_count (int)
  # - :outputs_count (int) (optionnel ici)
  # - :outputs_nonzero_count (int)
  # - :largest_output_btc (BigDecimal/num)
  #
  # Options:
  # - apply_threshold: true => retourne nil si sous min_btc (comportement scanner)
  # - apply_threshold: false => classifie quand même (utile pour backfill)
  #
  # Retour:
  # - nil si sous seuil ET apply_threshold=true
  # - sinon hash avec alert_type/score/ratio/exchange_likelihood/exchange_hint/meta
  def self.call(metrics, apply_threshold: true)
    m = metrics || {}

    total_out = m[:total_out_btc].to_d
    threshold = min_btc

    if apply_threshold && total_out < threshold
      return nil
    end

    inputs  = m[:inputs_count].to_i
    outs_nz = m[:outputs_nonzero_count].to_i

    largest = m[:largest_output_btc].to_d
    ratio   = total_out.positive? ? (largest / total_out) : 0.to_d

    alert_type = type_for(inputs: inputs, outs_nz: outs_nz, ratio: ratio)
    score      = score_for(total_out: total_out, inputs: inputs, outs_nz: outs_nz, ratio: ratio)

    ex = exchange_likelihood_for(
      total_out: total_out,
      inputs: inputs,
      outs_nz: outs_nz,
      ratio: ratio,
      alert_type: alert_type
    )

    {
      alert_type: alert_type,
      score: score,
      ratio: ratio.round(4),
      exchange_likelihood: ex[:score],
      exchange_hint: ex[:hint],
      meta: {
        threshold_btc: threshold.to_s,
        threshold_applied: apply_threshold,
        rules: rules_meta,
        exchange_reasons: ex[:reasons]
      }
    }
  end

  # -------------------------
  # Classification "type"
  # -------------------------
  def self.type_for(inputs:, outs_nz:, ratio:)
    if inputs >= 10 && outs_nz <= 3 && ratio >= 0.80
      "consolidation"
    elsif inputs <= 5 && outs_nz >= 20
      "distribution"
    elsif outs_nz >= 80
      "batching"
    else
      "other"
    end
  end

  def self.rules_meta
    {
      consolidation: { inputs_gte: 10, outs_nz_lte: 3, ratio_gte: 0.80 },
      distribution:  { inputs_lte: 5, outs_nz_gte: 20 },
      batching:      { outs_nz_gte: 80 }
    }
  end

  # -------------------------
  # Score simple (tri)
  # -------------------------
  def self.score_for(total_out:, inputs:, outs_nz:, ratio:)
    s = 0
    s += 40 if total_out >= 100
    s += 20 if total_out >= 500
    s += 10 if inputs >= 50
    s += 10 if outs_nz >= 100
    s += 10 if ratio >= 0.90
    [s, 100].min
  end

  # -------------------------
  # Heuristique "exchange-like"
  # -------------------------
  def self.exchange_likelihood_for(total_out:, inputs:, outs_nz:, ratio:, alert_type:)
    s = 0
    reasons = []

    if outs_nz >= 20
      s += 25
      reasons << "beaucoup de sorties"
    end

    if alert_type == "batching"
      s += 25
      reasons << "batching"
    end

    if ratio < 0.70
      s += 20
      reasons << "ratio faible"
    elsif ratio < 0.85 && outs_nz >= 20
      s += 10
      reasons << "ratio moyen"
    end

    if total_out >= 1000
      s += 15
      reasons << "montant très élevé"
    elsif total_out >= 300
      s += 10
      reasons << "montant élevé"
    end

    if inputs <= 3 && outs_nz >= 30
      s += 15
      reasons << "peu d'inputs vs beaucoup d'outputs"
    end

    s = [[s, 0].max, 100].min

    hint =
      if s >= 85
        "very-likely"
      elsif s >= 70
        "exchange-like"
      elsif s >= 45
        "possible"
      else
        "unlikely"
      end

    { score: s, hint: hint, reasons: reasons }
  end

  private_class_method :type_for, :rules_meta, :score_for, :exchange_likelihood_for
end
