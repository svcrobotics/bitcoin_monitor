# frozen_string_literal: true

# app/services/opsec_score_calculator.rb
class OpsecScoreCalculator
  Answer = Struct.new(:question_key, :answer, :risk_points, keyword_init: true)

  # Réponses autorisées (formulaire)
  ALLOWED_ANSWERS = %w[yes no unknown].freeze

  # V1: 15 questions (faciles à modifier/étendre)
  # weight: points de risque max
  # risk_if: :yes => "yes" est risqué ; :no => "no" est risqué (question de protection)
  QUESTIONS = [
    # A. Exposition publique
    { key: "published_crypto",      weight: 5, risk_if: :yes },
    { key: "same_pseudo_public",    weight: 4, risk_if: :yes },
    { key: "linkedin_location",     weight: 3, risk_if: :yes },
    { key: "showed_setup",          weight: 5, risk_if: :yes },

    # B. Identité & données
    { key: "same_email_exchange",   weight: 4, risk_if: :yes },
    { key: "phone_findable",        weight: 3, risk_if: :yes },
    { key: "identity_linkable",     weight: 4, risk_if: :yes },

    # C. Architecture des fonds
    { key: "funds_on_exchange",     weight: 4, risk_if: :yes },
    { key: "transferable_alone",    weight: 5, risk_if: :yes },
    { key: "decoy_wallet",          weight: 3, risk_if: :no }, # protection

    # D. Sécurité domicile
    { key: "close_ones_know",       weight: 4, risk_if: :yes },
    { key: "setup_visible_home",    weight: 3, risk_if: :yes },
    { key: "home_security",         weight: 2, risk_if: :no }, # protection

    # E. Résilience contrainte
    { key: "threat_plan",           weight: 3, risk_if: :no }, # protection
    { key: "separate_devices",      weight: 3, risk_if: :no }  # protection
  ].freeze

  def self.call(params_hash)
    new(params_hash).call
  end

  def initialize(params_hash)
    @raw = (params_hash || {}).transform_keys(&:to_s)
  end

  # Retourne un hash : score, risk_level, total_risk_points, max_risk_points, answers[]
  def call
    answers = build_answers
    total_risk = answers.sum(&:risk_points)
    max_risk   = QUESTIONS.sum { |q| q[:weight] }

    score = if max_risk.positive?
              (100 - ((total_risk.to_f / max_risk) * 100)).round
            else
              0
            end

    score = [[score, 0].max, 100].min
    risk_level = risk_level_for(score)

    {
      score: score,
      risk_level: risk_level,
      total_risk_points: total_risk,
      max_risk_points: max_risk,
      answers: answers
    }
  end

  private

  def build_answers
    QUESTIONS.map do |q|
      key = q[:key]
      ans = sanitize_answer(@raw[key])

      risk_points = risk_points_for(answer: ans, weight: q[:weight], risk_if: q[:risk_if])

      Answer.new(
        question_key: key,
        answer: ans,
        risk_points: risk_points
      )
    end
  end

  def sanitize_answer(v)
    s = v.to_s.strip.downcase
    return "unknown" if s.blank?
    return s if ALLOWED_ANSWERS.include?(s)
    "unknown"
  end

  def risk_points_for(answer:, weight:, risk_if:)
    case answer
    when "unknown"
      # Je ne sais pas = 50% du risque (arrondi au supérieur, plus prudent)
      (weight * 0.5).ceil
    when "yes"
      risk_if == :yes ? weight : 0
    when "no"
      risk_if == :no ? weight : 0
    else
      (weight * 0.5).ceil
    end
  end

  def risk_level_for(score)
    return "green"  if score >= 80
    return "yellow" if score >= 55
    "red"
  end
end
