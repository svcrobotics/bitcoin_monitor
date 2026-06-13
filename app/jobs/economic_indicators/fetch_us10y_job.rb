# frozen_string_literal: true

module EconomicIndicators
  class FetchUs10yJob
    include Sidekiq::Job

    sidekiq_options queue: :low, retry: 5

    def perform
      EconomicIndicators::FetchFredSeries.call(
        series_id: "DGS10",
        code: "us10y",
        name: "US 10-Year Treasury Yield"
      )
    end
  end
end
