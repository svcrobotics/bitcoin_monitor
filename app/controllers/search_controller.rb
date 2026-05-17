# frozen_string_literal: true

class SearchController < ApplicationController
  def index
    @q = params[:q].to_s.strip
    @results =
      if @q.present?
        Search::GlobalSearch.call(query: @q, limit: 20)
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
        Search::GlobalSearch.call(query: @q, limit: 6)
      else
        []
      end

    render partial: "search/results",
           locals: {
             results: @results,
             q: @q
           }
  end
end