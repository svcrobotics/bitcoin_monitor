# frozen_string_literal: true

# Classifie un mouvement "exchange-like" à partir de métriques transactionnelles.
# Ne dépend PAS d'un full node: uniquement des métriques déjà calculées par ton app.
#
# Input attendu (metrics Hash):
#   :total_in_btc, :total_out_btc
#   :inputs_count, :outputs_nonzero_count
#   :largest_output_btc
#   :seen_day, :spent_day (optionnel)
#   :timing_hint (optionnel) -> ex: :same_day_inflow_peak, :after_inflow_peak
#
class ExchangeFlowClassifier
  Bands = Struct.new(:retail, :desk, :whale, :inst, keyword_init: true)

  DEFAULT_BANDS = Bands.new(
    retail: 100.to_d,   # < 100 BTC
    desk:   500.to_d,   # 100..500 BTC
    whale:  2_000.to_d, # 500..2000 BTC
    inst:   2_000.to_d  # > 2000 BTC
  )

  Result = Struct.new(
    :movement_kind, :flow_kind, :actor_band,
    :confidence, :internal_score, :external_score, :inter_score,
    :reasons, :meta,
    keyword_init: true
  )

  def self.call(metrics, movement_kind:, bands: DEFAULT_BANDS)
    new(metrics, movement_kind: movement_kind, bands: bands).call
  end

  def initialize(metrics, movement_kind:, bands:)
    @m = (metrics || {}).transform_keys(&:to_sym)
    @movement_kind = movement_kind.to_sym
    @bands = bands
  end

  def call
    total_out = d(:total_out_btc)
    inputs    = i(:inputs_count)
    outs_nz   = i(:outputs_nonzero_count)
    largest   = d(:largest_output_btc)
    ratio     = total_out.positive? ? (largest / total_out) : 0.to_d

    internal_score = 0
    external_score = 0
    inter_score    = 0
    reasons = []

    # -------------------------
    # 1) Internal (consolidation / hot->cold) heuristics
    # -------------------------
    if inputs >= 20
      internal_score += 2
      reasons << "Beaucoup d'inputs (#{inputs}) → consolidation interne probable."
    elsif inputs >= 10
      internal_score += 1
      reasons << "Inputs élevés (#{inputs}) → mouvement interne possible."
    end

    if outs_nz <= 3
      internal_score += 2
      reasons << "Peu d'outputs (#{outs_nz}) → pattern hot→cold/consolidation."
    elsif outs_nz <= 6
      internal_score += 1
      reasons << "Outputs faibles (#{outs_nz}) → pattern interne possible."
    end

    if ratio >= 0.90
      internal_score += 2
      reasons << "Sortie dominante (ratio #{pct(ratio)}) → transfert interne probable."
    elsif ratio >= 0.75
      internal_score += 1
      reasons << "Sortie très dominante (ratio #{pct(ratio)}) → interne possible."
    end

    # Timing (optionnel, fourni par ton daily builder)
    case @m[:timing_hint].to_s
    when "same_day_inflow_peak"
      internal_score += 1
      reasons << "Timing: gros inflow le même jour → gestion interne probable."
    when "after_inflow_peak"
      internal_score += 1
      reasons << "Timing: juste après gros inflow → consolidation/stockage probable."
    end

    # -------------------------
    # 2) External (withdrawals / distribution) heuristics
    # -------------------------
    if outs_nz >= 20
      external_score += 2
      reasons << "Beaucoup d'outputs (#{outs_nz}) → retraits clients/distribution probable."
    elsif outs_nz >= 10
      external_score += 1
      reasons << "Outputs élevés (#{outs_nz}) → distribution possible."
    end

    if ratio <= 0.20 && total_out >= 50.to_d
      external_score += 2
      reasons << "Aucune sortie dominante (ratio #{pct(ratio)}) → distribution probable."
    elsif ratio <= 0.35 && total_out >= 50.to_d
      external_score += 1
      reasons << "Ratio faible (#{pct(ratio)}) → distribution possible."
    end

    if inputs <= 5 && ratio >= 0.90 && total_out >= 100.to_d
      external_score += 2
      reasons << "Peu d'inputs (#{inputs}) + sortie dominante → gros retrait externe possible."
    end

    # -------------------------
    # 3) Inter-exchange (si tu as un score d'“exchange-likelihood” côté destination)
    #    (optionnel: tu peux l'ajouter plus tard)
    # -------------------------
    # Exemple:
    # if @m[:dest_exchange_like].to_i == 1
    #   inter_score += 3
    #   reasons << "Destination exchange-like détectée → inter-exchange possible."
    # end

    flow_kind, confidence = decide_kind(internal_score, external_score, inter_score)

    actor_band =
      if total_out < @bands.retail
        :retail_probable
      elsif total_out < @bands.desk
        :desk_probable
      elsif total_out < @bands.whale
        :whale_probable
      else
        :institution_probable
      end

    Result.new(
      movement_kind: @movement_kind,
      flow_kind: flow_kind,
      actor_band: actor_band,
      confidence: confidence,
      internal_score: internal_score,
      external_score: external_score,
      inter_score: inter_score,
      reasons: reasons,
      meta: {
        total_out_btc: total_out.to_s("F"),
        inputs_count: inputs,
        outputs_nonzero_count: outs_nz,
        largest_output_btc: largest.to_s("F"),
        ratio: ratio.to_s("F")
      }
    )
  end

  private

  def decide_kind(internal, external, inter)
    top = { internal: internal, external: external, inter_exchange: inter }.sort_by { |_k,v| -v }
    best_k, best_v = top[0]
    second_v = top[1][1]

    # Pas assez d'info
    return [:unknown, 20] if best_v <= 1

    # marge = différence entre best et second
    margin = best_v - second_v

    kind =
      case best_k
      when :internal then :internal
      when :external then :external
      else :inter_exchange
      end

    # confidence simple et lisible
    conf =
      if best_v >= 6 && margin >= 3 then 85
      elsif best_v >= 5 && margin >= 2 then 75
      elsif best_v >= 4 && margin >= 1 then 60
      else 45
      end

    [kind, conf]
  end

  def d(key) = (@m[key] || 0).to_d
  def i(key) = (@m[key] || 0).to_i
  def pct(x)  = "#{(x * 100).round(1)}%"
end
