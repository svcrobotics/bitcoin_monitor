# frozen_string_literal: true

class AddressUtxoProjectionBlock < ApplicationRecord
  STATUSES = %w[
    pending
    processing
    completed
    failed
    stale
  ].freeze

  validates :height,
    presence: true,
    uniqueness: true,
    numericality: {
      only_integer: true,
      greater_than_or_equal_to: 0
    }

  validates :block_hash,
    presence: true

  validates :status,
    presence: true,
    inclusion: {
      in: STATUSES
    }

  validates :attempts,
    :received_output_count,
    :spent_output_count,
    :received_address_count,
    :spent_address_count,
    :total_received_sats,
    :total_spent_sats,
    numericality: {
      only_integer: true,
      greater_than_or_equal_to: 0
    }

  validate :completed_requires_completed_at

  scope :completed, -> {
    where(status: "completed")
  }

  scope :pending_or_failed, -> {
    where(status: %w[pending failed])
  }

  scope :by_height, -> {
    order(:height)
  }

  def completed?
    status == "completed"
  end

  private

  def completed_requires_completed_at
    return unless completed?
    return if completed_at.present?

    errors.add(
      :completed_at,
      :blank
    )
  end
end
