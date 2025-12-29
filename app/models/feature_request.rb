# app/models/feature_request.rb
class FeatureRequest < ApplicationRecord
  STATUSES = %w[pending awaiting_payment paid in_progress done rejected]

  validates :title, :description, presence: true
  validates :amount_sats, numericality: { greater_than_or_equal_to: 0 }
  validates :status, inclusion: { in: STATUSES }

  def paid?
    %w[paid in_progress done].include?(status)
  end
end
