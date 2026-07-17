# frozen_string_literal: true

module Questions
  class LiveAnswersController < ApplicationController
    def show
      response.headers["Cache-Control"] = "no-store"

      @module_name = params[:module_name].to_s

      render layout: false
    end
  end
end
