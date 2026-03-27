# frozen_string_literal: true

# app/services/market_synthesis.rb
#
# Objectif:
# - Fournir une synthèse macro descriptive sur 30j
# - Basée uniquement sur les keys des indicateurs existants
# - Aucune prédiction, aucune action
#
class MarketSynthesis
  Result = Struct.new(
    :title,
    :summary,
    :badge_cls,
    :window_days,
    keyword_init: true
  )

  def self.call(
    window_days: 30,
    pressure: nil,
    maturity: nil,
    absorption: nil
  )
    press_txt =
      case pressure&.key
      when :high    then "pression spéculative élevée"
      when :cleanup then "pression spéculative en digestion"
      when :calm    then "pression spéculative faible"
      else nil
      end

    mat_txt =
      case maturity&.key
      when :immature   then "marché immature"
      when :transition then "marché en transition"
      when :mature     then "marché mature"
      else nil
      end

    abs_txt =
      case absorption&.key
      when :absorption   then "absorption en cours"
      when :distribution then "distribution en cours"
      when :neutral      then "réaction du prix neutre"
      else nil
      end

    parts = [press_txt, mat_txt, abs_txt].compact
    summary =
      if parts.any?
        parts.join(", ").capitalize + "."
      else
        "Données insuffisantes pour établir une synthèse fiable."
      end

    Result.new(
      title: "Synthèse du marché",
      summary: summary,
      badge_cls: "text-indigo-200 bg-indigo-500/10 border-indigo-700/50",
      window_days: window_days
    )
  end
end
