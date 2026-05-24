require 'rails_helper'

RSpec.describe "MarketSignals", type: :request do
  describe "GET /index" do
    it "returns http success" do
      get "/market_signals/index"
      expect(response).to have_http_status(:success)
    end
  end

end
