# frozen_string_literal: true

module EconomicIndicators
  class FetchFedFundsRateJob
    include Sidekiq::Job

    sidekiq_options queue: :low, retry: 5

    def perform
      EconomicIndicators::FetchFredSeries.call(
        series_id: "DFF",
        code: "fed_funds_rate",
        name: "Effective Federal Funds Rate"
      )
    end
  end
end
