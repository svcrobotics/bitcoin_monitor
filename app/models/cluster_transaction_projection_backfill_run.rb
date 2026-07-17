# frozen_string_literal: true

class ClusterTransactionProjectionBackfillRun < ApplicationRecord
  STATUSES = %w[pending running paused completed failed stale].freeze

  has_many(
    :items,
    class_name: "ClusterTransactionProjectionBackfillItem",
    foreign_key: :run_id,
    inverse_of: :run,
    dependent: :destroy
  )

  has_many(
    :addresses,
    class_name: "ClusterTransactionProjectionBackfillAddress",
    foreign_key: :run_id,
    inverse_of: :run,
    dependent: :delete_all
  )

  validates :target_checkpoint_height,
    numericality: {
      only_integer: true,
      greater_than_or_equal_to: 0
    }

  validates :target_checkpoint_hash,
    :status,
    :source,
    presence: true

  validates :status,
    inclusion: {
      in: STATUSES
    }

  scope :active, -> {
    where(status: %w[pending running paused])
  }

  def completed?
    status == "completed"
  end

  def stale?
    status == "stale"
  end
end
