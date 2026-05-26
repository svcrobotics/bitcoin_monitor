# app/controllers/actors/whale_core_flows_controller.rb
module Actors
  class WhaleCoreFlowsController < ApplicationController
    def index
      @signal = MarketSignal
        .where(source: "tansa", indicator: "WHALE_CORE_FLOW")
        .order(observed_on: :desc)
        .first

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
