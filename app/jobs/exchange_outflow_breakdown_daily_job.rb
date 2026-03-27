# frozen_string_literal: true

class ExchangeOutflowBreakdownDailyJob < ApplicationJob
  queue_as :low

  def perform(day_str = nil)
    day = day_str.present? ? Date.parse(day_str) : Date.yesterday
    ExchangeOutflowBreakdownBuilder.call(day: day)
  end
end