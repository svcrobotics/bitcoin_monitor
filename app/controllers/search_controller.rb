# frozen_string_literal: true

class SearchController < ApplicationController
  def index
    @q = params[:q].to_s.strip

    if etf_question?(@q) && turbo_frame_request?
      etf_candidates = ActorLabels::EtfCandidatesAnswer.call

      render partial: "search/answers/etf_candidates",
             locals: {
               data: etf_candidates,
               q: @q
             }

      return
    end

    if pressure_question?(@q) && turbo_frame_request?
      @netflow = Dashboard::ExchangeCoreNetflowToday.call

      render partial: "search/answers/exchange_core_flow",
             locals: {
               netflow: @netflow,
               q: @q
             }

      return
    end

    @results =
      if @q.present?
        build_results(@q)
      else
        []
      end
  rescue StandardError => e
    @results = []
    @error = "#{e.class}: #{e.message}"
  end

  def live
    @q = params[:q].to_s.strip

    @results =
      if @q.present?
        build_results(@q, limit: 6)
      else
        []
      end

    render partial: "search/results",
           locals: {
             results: @results,
             q: @q
           }
  end

  def etf_question?(query)
    normalize_query(query).match?(/\betf\b|etf_candidate|etf candidates|fonds bitcoin|institutionnel/)
  end

  private

  def build_results(query, limit: 20)
    question_matches = question_results(query)

    search_results =
      Search::GlobalSearch.call(
        query: query,
        limit: limit
      )

    question_matches + Array(search_results)
  end

  def question_results(query)
    return [] if query.blank?

    QuestionDefinition
      .active
      .where("question ILIKE :q OR intent ILIKE :q OR module_name ILIKE :q", q: "%#{query}%")
      .ordered
      .limit(5)
      .map do |question|
        {
          kind: "question",
          title: question.question,
          description: "Réponse analytique basée sur les données Bitcoin Monitor.",
          key: question.key,
          turbo_path: question_path(question.key),
          module_path: question.historical_path,
          module_name: question.module_name.humanize,
          tier: question.tier
        }
      end
  end

  def pressure_question?(_query)
    false
  end

  def normalize_query(value)
    value.to_s.downcase.strip
  end
end