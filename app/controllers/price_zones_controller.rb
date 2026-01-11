class PriceZonesController < ApplicationController
  def refresh
    MarketData::ComputePriceZones.new.call
    redirect_to dashboard_path, notice: "Zones de prix recalculées ✅"
  rescue => e
    redirect_to dashboard_path, alert: "Erreur recalcul zones: #{e.message}"
  end
end
