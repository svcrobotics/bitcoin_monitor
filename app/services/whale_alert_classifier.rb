# frozen_string_literal: true

# app/services/whale_alert_classifier.rb
class WhaleAlertClassifier
  DEFAULT_MIN_BTC = "100"

  # Segmentation (peut être ajustée via ENV si tu veux plus tard)
  RETAIL_MAX_BTC = ENV.fetch("BAND_RETAIL_MAX_BTC", "100").to_d
  DESK_MAX_BTC   = ENV.fetch("BAND_DESK_MAX_BTC",   "500").to_d
  WHALE_MAX_BTC  = ENV.fetch("BAND_WHALE_MAX_BTC",  "2000").to_d

  def self.min_btc
    ENV.fetch("WHALE_MIN_BTC", DEFAULT_MIN_BTC).to_d
  end

  def self.call(metrics, apply_threshold: true)
    m = (metrics || {}).transform_keys(&:to_sym)

    total_out = m[:total_out_btc].to_d
    threshold = min_btc
    return nil if apply_threshold && total_out < threshold

    inputs  = m[:inputs_count].to_i
    outs_nz = m[:outputs_nonzero_count].to_i

    largest = m[:largest_output_btc].to_d
    ratio   = total_out.positive? ? (largest / total_out) : 0.to_d

    alert_type = type_for(inputs: inputs, outs_nz: outs_nz, ratio: ratio)
    score      = score_for(total_out: total_out, inputs: inputs, outs_nz: outs_nz, ratio: ratio, alert_type: alert_type)

    ex = exchange_likelihood_for(
      total_out: total_out,
      inputs: inputs,
      outs_nz: outs_nz,
      ratio: ratio,
      alert_type: alert_type
    )

    # ✅ Nouveau : classification "internal vs external" + band + confidence
    flow = flow_kind_for(
      total_out: total_out,
      inputs: inputs,
      outs_nz: outs_nz,
      ratio: ratio,
      alert_type: alert_type,
      # optionnel : ton builder peut passer :timing_hint (same_day_inflow_peak / after_inflow_peak)
      timing_hint: m[:timing_hint]
      # optionnel futur : m[:dest_exchange_like] (si tu ajoutes un détecteur de dest exchange-like)
      # dest_exchange_like: m[:dest_exchange_like]
    )

    band = actor_band_for(total_out)

    {
      alert_type: alert_type,
      score: score,
      ratio: ratio.round(4),

      exchange_likelihood: ex[:score],
      exchange_hint: ex[:hint],

      # ✅ Nouveaux champs
      flow_kind: flow[:kind],                 # internal / external / inter_exchange / unknown
      flow_confidence: flow[:confidence],     # 0..100
      actor_band: band,                       # retail_probable / desk_probable / whale_probable / institution_probable
      flow_reasons: flow[:reasons],           # array pour UI "Comprendre"
      flow_scores: flow[:scores],             # debug / tuning

      meta: {
        threshold_btc: threshold.to_s,
        threshold_applied: apply_threshold,
        rules: rules_meta,
        exchange_reasons: ex[:reasons],
        timing_hint: m[:timing_hint]
      }
    }
  end

  # -------------------------
  # Classification "type"
  # -------------------------
  def self.type_for(inputs:, outs_nz:, ratio:)
    # 1) batching: énormément d'outputs
    return "batching" if outs_nz >= 80

    # 2) distribution: peu d'inputs et beaucoup d'outputs
    return "distribution" if inputs <= 5 && outs_nz >= 20

    # 3) consolidation: beaucoup d'inputs -> peu d'outputs (ratio pas obligatoire)
    return "consolidation" if inputs >= 10 && outs_nz <= 3

    # 4) single destination: très peu d'outputs + une sortie domine très fort
    return "single_destination" if outs_nz <= 5 && ratio >= 0.95

    # ✅ Nouveau : ratio "extrême" tolère un peu plus d'outputs (change split, dust management…)
    return "single_destination" if outs_nz <= 12 && ratio >= 0.98

    "other"
  end

  def self.rules_meta
    {
      batching:            { outs_nz_gte: 80 },
      distribution:        { inputs_lte: 5, outs_nz_gte: 20 },
      consolidation:       { inputs_gte: 10, outs_nz_lte: 3 },
      single_destination:  { outs_nz_lte: 5, ratio_gte: 0.95 }
    }
  end

  # -------------------------
  # Score (tri)
  # -------------------------
  def self.score_for(total_out:, inputs:, outs_nz:, ratio:, alert_type:)
    s = 0

    # Taille
    s += 30 if total_out >= 250
    s += 25 if total_out >= 500
    s += 20 if total_out >= 1000
    s += 10 if total_out >= 2000

    # Complexité / pattern
    s += 10 if inputs >= 50
    s += 10 if outs_nz >= 100
    s += 10 if ratio >= 0.90
    s += 5  if ratio <= 0.60 && outs_nz >= 20

    # Bonus par type (priorité "signal")
    case alert_type
    when "batching"            then s += 12
    when "distribution"        then s += 10
    when "consolidation"       then s += 7
    when "single_destination"  then s += 4
    end

    [[s, 0].max, 100].min
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

    if alert_type == "single_destination" && total_out >= 1000
      s += 10
      reasons << "single destination + très gros montant"
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

  # -------------------------
  # ✅ Nouveau : flow_kind (internal vs external…)
  # -------------------------
  def self.flow_kind_for(total_out:, inputs:, outs_nz:, ratio:, alert_type:, timing_hint: nil, dest_exchange_like: nil)
    internal = 0
    external = 0
    inter    = 0
    reasons  = []

    # --- INTERNAL (gestion interne / consolidation / hot->cold) ---
    if inputs >= 20
      internal += 2
      reasons << "inputs élevés (#{inputs}) → consolidation interne probable"
    elsif inputs >= 10
      internal += 1
      reasons << "inputs assez élevés (#{inputs}) → interne possible"
    end

    if outs_nz <= 3
      internal += 2
      reasons << "peu d'outputs (#{outs_nz}) → pattern hot→cold/consolidation"
    elsif outs_nz <= 6
      internal += 1
      reasons << "outputs faibles (#{outs_nz}) → interne possible"
    end

    if ratio >= 0.90
      internal += 2
      reasons << "sortie dominante (#{(ratio * 100).round(1)}%) → interne probable"
    elsif ratio >= 0.75
      internal += 1
      reasons << "sortie très dominante (#{(ratio * 100).round(1)}%) → interne possible"
    end

    case timing_hint.to_s
    when "same_day_inflow_peak"
      internal += 1
      reasons << "timing: gros inflow le même jour → gestion interne probable"
    when "after_inflow_peak"
      internal += 1
      reasons << "timing: juste après gros inflow → consolidation/stockage probable"
    end

    # Bonus direct si ton type est déjà "consolidation"
    if alert_type == "consolidation"
      internal += 1
      reasons << "type=consolidation → interne renforcé"
    end

    # --- EXTERNAL (withdrawals / distribution) ---
    if outs_nz >= 30
      external += 2
      reasons << "beaucoup d'outputs (#{outs_nz}) → retraits/distribution probable"
    elsif outs_nz >= 20
      external += 1
      reasons << "outputs élevés (#{outs_nz}) → distribution possible"
    end

    if ratio <= 0.20 && total_out >= 50.to_d
      external += 2
      reasons << "aucune sortie dominante (#{(ratio * 100).round(1)}%) → distribution probable"
    elsif ratio <= 0.35 && total_out >= 50.to_d
      external += 1
      reasons << "ratio faible (#{(ratio * 100).round(1)}%) → distribution possible"
    end

    # ✅ Tie-breaker simple : 1-2 inputs + ratio très haut + outputs pas énormes
    # Souvent un gros retrait (withdrawal) plutôt qu'une gestion interne.
    if inputs <= 2 && ratio >= 0.95 && outs_nz <= 12
      external += 1
      reasons << "tie-breaker: 1–2 inputs + ratio très haut + outputs modérés → retrait externe favorisé"
    end

    if inputs <= 5 && ratio >= 0.90 && total_out >= 100.to_d
      external += 2
      reasons << "peu d'inputs (#{inputs}) + sortie dominante → gros retrait externe possible"
    end

    if alert_type == "distribution" || alert_type == "batching"
      external += 1
      reasons << "type=#{alert_type} → externe/distribution renforcé"
    end

    # --- INTER-EXCHANGE (optionnel, si tu ajoutes un signal de destination) ---
    if dest_exchange_like.to_i == 1
      inter += 3
      reasons << "destination exchange-like détectée → inter-exchange possible"
    end

    # Décision
    kind, confidence = decide_flow_kind(internal: internal, external: external, inter: inter)

    {
      kind: kind,
      confidence: confidence,
      reasons: reasons,
      scores: { internal: internal, external: external, inter_exchange: inter }
    }
  end

  def self.decide_flow_kind(internal:, external:, inter:)
    ordered = { internal: internal, external: external, inter_exchange: inter }.sort_by { |_k, v| -v }
    best_k, best_v = ordered[0]
    second_v       = ordered[1][1]

    return ["unknown", 20] if best_v <= 1

    margin = best_v - second_v

    # ✅ Nouveau : si égalité (margin=0) et scores "significatifs", ne tranche pas arbitrairement
    if margin == 0 && best_v >= 2
      return ["unknown", 35]
    end

    kind =
      case best_k
      when :internal then "internal"
      when :external then "external"
      else "inter_exchange"
      end

    conf =
      if best_v >= 6 && margin >= 3 then 85
      elsif best_v >= 5 && margin >= 2 then 75
      elsif best_v >= 4 && margin >= 1 then 60
      else 45
      end

    [kind, conf]
  end

  # -------------------------
  # ✅ Nouveau : actor band (retail/desk/whale/inst)
  # -------------------------
  def self.actor_band_for(total_out)
    if total_out < RETAIL_MAX_BTC
      "retail_probable"
    elsif total_out < DESK_MAX_BTC
      "desk_probable"
    elsif total_out < WHALE_MAX_BTC
      "whale_probable"
    else
      "institution_probable"
    end
  end

  private_class_method :type_for, :rules_meta, :score_for, :exchange_likelihood_for,
                       :flow_kind_for, :decide_flow_kind, :actor_band_for
end
