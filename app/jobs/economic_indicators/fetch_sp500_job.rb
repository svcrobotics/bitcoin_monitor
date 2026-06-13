# frozen_string_literal: true

module EconomicIndicators
  class FetchSp500Job
    include Sidekiq::Job

    sidekiq_options queue: :low, retry: 5

    def perform
      EconomicIndicators::FetchFredSeries.call(
        series_id: "SP500",
        code: "sp500",
        name: "S&P 500"
      )
    end
  end
end
