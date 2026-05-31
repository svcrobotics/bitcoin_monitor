# frozen_string_literal: true

class DashboardController < ApplicationController
  def index
  end

  def exchange_core_netflow
    @netflow = Dashboard::ExchangeCoreNetflowToday.call

    render partial: "dashboard/exchange_core_netflow",
           locals: { netflow: @netflow }
  end
end