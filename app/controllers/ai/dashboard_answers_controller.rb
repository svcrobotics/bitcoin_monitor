# frozen_string_literal: true

module Ai
  class DashboardAnswersController < ApplicationController
    def create
      @question = params[:q].to_s.strip

      route = Intelligence::Router.call(@question)

      @context = route[:context] || {}
      @intent = route[:intent]
      @source = route[:source]

      result =
        case @intent
        when :codebase
          Ai::CodebaseAnswerer.call(
            question: @question
          )

        when :layer1_health
          Intelligence::Layer1Assistant.call(
            question: @question,
            context: @context
          )

        when :cluster_health
          Intelligence::ClusterAssistant.call(
            question: @question,
            context: @context
          )

        when :actor_profiles_health
          Intelligence::ActorProfilesAssistant.call(
            question: @question,
            context: @context
          )

        when :actor_behaviors_health
          Intelligence::ActorBehaviorsAssistant.call(
            question: @question,
            context: @context
          )

        when :actor_labels_health
          Intelligence::ActorLabelsAssistant.call(
            question: @question,
            context: @context
          )

        when :system_health
          Intelligence::SystemAssistant.call(
            question: @question,
            context: @context
          )

        when :ollama_anomaly
          Intelligence::OllamaAnomalyAssistant.call(
            question: @question,
            context: @context
          )

        else
          Intelligence::UserAssistant.call(
            question: @question,
            context: @context
          )
        end

      @answer =
        result.is_a?(Hash) ?
          result[:answer] :
          result

      @sources =
        result.is_a?(Hash) ?
          Array(result[:sources]) :
          []

      respond_to do |format|
        format.turbo_stream

        format.html do
          render(
            partial: "ai/dashboard_answer",
            locals: {
              answer: @answer,
              context: @context,
              intent: @intent,
              source: @source,
              sources: @sources
            }
          )
        end
      end
    end
  end
end
