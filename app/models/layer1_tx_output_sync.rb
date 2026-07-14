# frozen_string_literal: true

class Layer1TxOutputSync < ApplicationRecord
  STATUSES = %w[pending processing synced failed].freeze

  validates :height, presence: true, uniqueness: true
  validates :block_hash, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :pending_first, -> { where(status: %w[pending failed]).order(:height) }
  scope :synced, -> { where(status: "synced") }
end
