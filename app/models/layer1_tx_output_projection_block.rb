# frozen_string_literal: true

class Layer1TxOutputProjectionBlock < ApplicationRecord
  STATUSES = %w[
    pending
    processing
    projected
    failed
    stale
  ].freeze

  validates :height, presence: true, uniqueness: true
  validates :block_hash, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }

  validates :expected_outputs_count,
    :projected_outputs_count,
    :rows_inserted,
    :rows_skipped,
    :attempts,
    numericality: {
      only_integer: true,
      greater_than_or_equal_to: 0
    }

  validates :expected_outputs_value_btc,
    :projected_outputs_value_btc,
    numericality: {
      greater_than_or_equal_to: 0
    }

  scope :pending_first, lambda {
    where(status: %w[pending failed]).order(:height)
  }

  scope :projected, -> { where(status: "projected") }
  scope :failed, -> { where(status: "failed") }
  scope :stale, -> { where(status: "stale") }
end
