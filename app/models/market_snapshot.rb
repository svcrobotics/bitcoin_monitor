class MarketSnapshot < ApplicationRecord
  scope :latest_ok, -> { where(status: "ok").order(computed_at: :desc).first }
end
