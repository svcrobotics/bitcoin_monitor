# app/controllers/ai/dashboard_answers_controller.rb

module Ai
  class DashboardAnswersController < ApplicationController
    def create
      question = params[:q].to_s.strip

      context = Intelligence::ContextBuilder.exchange_flow

      @answer = Intelligence::UserAssistant.call(
        question: question,
        context: context
      )

      @context = context

      render partial: "ai/dashboard_answer", locals: {
        answer: @answer,
        context: @context
      }
    end
  end
end
