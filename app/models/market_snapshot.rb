class MarketSnapshot < ApplicationRecord
  scope :ok_status, -> { where(status: "ok") }

  def self.latest_ok
    ok_status.order(computed_at: :desc).first
  end
end