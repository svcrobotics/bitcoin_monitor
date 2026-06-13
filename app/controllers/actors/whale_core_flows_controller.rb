# app/controllers/actors/whale_core_flows_controller.rb
module Actors
  class WhaleCoreFlowsController < ApplicationController
    def index
      @days = WhaleCoreFlowDay
        .where("events_count > 0")
        .order(day: :desc)
        .limit(30)

      @latest_day = @days.first

      @whale_labels = ActorLabel
        .where(label: "whale_like")
        .order(confidence: :desc, updated_at: :desc)
        .limit(20)
    end
  end
end
