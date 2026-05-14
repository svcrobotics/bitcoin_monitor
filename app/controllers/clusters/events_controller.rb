# frozen_string_literal: true

module Clusters
  class EventsController < ApplicationController
    def index
      @q = params[:q].to_s.strip
      @source = params[:source].presence
      @severity = params[:severity].presence
      @signal_type = params[:signal_type].presence

      @events = Clusters::ClickHouseEventReader.recent(
        limit: 100,
        q: @q,
        source: @source,
        severity: @severity,
        signal_type: @signal_type
      )

      @stats = {
        total: @events.size,
        high: @events.count { |event| event["severity"] == "high" },
        realtime: @events.count { |event| event["source"] == "cluster_realtime" },
        business: @events.count { |event| event["source"] == "cluster_business" },
        top_score: @events.map { |event| event["score"].to_i }.max || 0
      }
    end
  end
end
