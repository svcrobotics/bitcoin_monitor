# frozen_string_literal: true

class Event < ApplicationRecord
  # -----------------------------
  # VALIDATIONS
  # -----------------------------
  validates :event_type, presence: true

  # -----------------------------
  # SCOPES
  # -----------------------------
  scope :by_type, ->(type) { where(event_type: type) }
  scope :recent, -> { order(created_at: :desc) }

  # -----------------------------
  # HELPERS
  # -----------------------------
  def tx_event?
    txid.present?
  end
end