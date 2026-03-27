# frozen_string_literal: true

class OpsecAssessmentsController < ApplicationController
  # Accessible à tous : pas d’auth
  def new
    @questions = OpsecScoreCalculator::QUESTIONS
  end

  def create
    # Les réponses arrivent sous params[:opsec] (on va faire pareil dans la vue)
    opsec_params = params.fetch(:opsec, {}).permit(*OpsecScoreCalculator::QUESTIONS.map { |q| q[:key] })

    result = OpsecScoreCalculator.call(opsec_params.to_h)

    assessment = OpsecAssessment.create!(
      score: result[:score],
      risk_level: result[:risk_level],
      total_risk_points: result[:total_risk_points],
      max_risk_points: result[:max_risk_points]
    )

    result[:answers].each do |a|
      assessment.opsec_answers.create!(
        question_key: a.question_key,
        answer: a.answer,
        risk_points: a.risk_points
      )
    end

    redirect_to opsec_assessment_path(assessment)
  end

  def show
    @assessment = OpsecAssessment.includes(:opsec_answers).find(params[:id])
    @answers = @assessment.opsec_answers.index_by(&:question_key)
    @questions = OpsecScoreCalculator::QUESTIONS
  end
end
