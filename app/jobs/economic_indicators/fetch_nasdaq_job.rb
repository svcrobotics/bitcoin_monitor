# frozen_string_literal: true

module EconomicIndicators
  class FetchNasdaqJob
    include Sidekiq::Job

    sidekiq_options queue: :low, retry: 5

    def perform
      EconomicIndicators::FetchFredSeries.call(
        series_id: "NASDAQCOM",
        code: "nasdaq",
        name: "NASDAQ Composite Index"
      )
    end
  end
end
