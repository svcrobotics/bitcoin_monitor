# frozen_string_literal: true

class AddressSpendProjectionBlock < ApplicationRecord
  STATUSES = %w[
    pending
    processing
    completed
    failed
  ].freeze

  validates(
    :height,
    presence: true,
    uniqueness: true,
    numericality: {
      only_integer: true,
      greater_than_or_equal_to: 0
    }
  )

  validates(
    :block_hash,
    presence: true
  )

  validates(
    :status,
    presence: true,
    inclusion: {
      in: STATUSES
    }
  )

  validates(
    :input_count,
    :address_count,
    :total_sent_sats,
    :attempts,
    numericality: {
      only_integer: true,
      greater_than_or_equal_to: 0
    }
  )

  scope :pending, -> {
    where(status: "pending")
  }

  scope :processing, -> {
    where(status: "processing")
  }

  scope :completed, -> {
    where(status: "completed")
  }

  scope :failed, -> {
    where(status: "failed")
  }

  def completed?
    status == "completed"
  end
end
