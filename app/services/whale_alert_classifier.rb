# frozen_string_literal: true

class WhaleAlertClassifier
  MIN_BTC = ENV.fetch("WHALE_MIN_BTC", "100").to_d

  def self.call(metrics)
    total_out = metrics[:total_out_btc].to_d
    return nil if total_out < MIN_BTC

    inputs  = metrics[:inputs_count].to_i
    outs_nz = metrics[:outputs_nonzero_count].to_i

    largest = metrics[:largest_output_btc].to_d
    ratio   = total_out.positive? ? (largest / total_out) : 0.to_d

    alert_type =
      if inputs >= 10 && outs_nz <= 3 && ratio >= 0.80
        "consolidation"
      elsif inputs <= 5 && outs_nz >= 20
        "distribution"
      elsif outs_nz >= 80
        "batching"
      else
        "other"
      end

    score = score_for(total_out:, inputs:, outs_nz:, ratio:)

    {
      alert_type:,
      score:,
      ratio: ratio.round(4),
      meta: {
        min_btc: MIN_BTC.to_s,
        rules: {
          consolidation: { inputs_gte: 10, outs_nz_lte: 3, ratio_gte: 0.80 },
          distribution:  { inputs_lte: 5, outs_nz_gte: 20 },
          batching:      { outs_nz_gte: 80 }
        }
      }
    }
  end

  def self.score_for(total_out:, inputs:, outs_nz:, ratio:)
    s = 0
    s += 40 if total_out >= 100
    s += 20 if total_out >= 500
    s += 10 if inputs >= 50
    s += 10 if outs_nz >= 100
    s += 10 if ratio >= 0.90
    [s, 100].min
  end
end
