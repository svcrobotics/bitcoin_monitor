# frozen_string_literal: true

class ClusterTransactionProjectionBlock < ApplicationRecord
  STATUSES =
    %w[pending processing projected failed stale].freeze

  validates :block_height,
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

  validate :projected_block_has_completed_at

  scope :completed, -> {
    where(status: "projected")
  }

  scope :projected, -> {
    where(status: "projected")
  }

  def projected?
    status == "projected"
  end

  private

  def projected_block_has_completed_at
    return unless projected?
    return if completed_at.present?

    errors.add(:completed_at, :blank)
  end
end
