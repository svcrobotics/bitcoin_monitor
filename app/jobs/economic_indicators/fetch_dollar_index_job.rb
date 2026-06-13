# frozen_string_literal: true

module EconomicIndicators
  class FetchDollarIndexJob
    include Sidekiq::Job

    sidekiq_options queue: :low, retry: 5

    def perform
      result = EconomicIndicators::FetchFredSeries.call(
        series_id: "DTWEXBGS",
        code: "dollar_index_broad",
        name: "Trade Weighted U.S. Dollar Index: Broad"
      )

      Rails.logger.info("[economic_indicators] dollar index fetched #{result.inspect}")
    end
  end
end
