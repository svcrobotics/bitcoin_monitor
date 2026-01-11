# app/services/market_data/refresh_market_context.rb
module MarketData
  class RefreshMarketContext
    def initialize(days: 365, logger: Rails.logger)
      @days   = days
      @logger = logger
    end

    def call
      MarketData::FetchDailyPrices.new(days: @days, logger: @logger).call
      MarketData::ComputeMarketContext.new(logger: @logger).call
    end
  end
end
