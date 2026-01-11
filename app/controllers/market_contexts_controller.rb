class MarketContextsController < ApplicationController
  def refresh
    MarketData::RefreshMarketContext.new(days: 365).call
    redirect_to dashboard_path, notice: "Contexte marché mis à jour ✅"
  rescue => e
    redirect_to dashboard_path, alert: "Erreur refresh contexte marché: #{e.message}"
  end
end
