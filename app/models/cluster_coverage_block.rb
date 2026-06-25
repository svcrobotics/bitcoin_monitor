# frozen_string_literal: true

class ClusterCoverageBlock < ApplicationRecord
  STATUSES = %w[
    pending
    processing
    deferred
    completed
    failed
  ].freeze

  validates :height,
    presence: true,
    uniqueness: true

  validates :block_hash,
    presence: true

  validates :status,
    presence: true,
    inclusion: {
      in: STATUSES
    }

  scope :pending_or_failed, lambda {
    where(
      status: %w[
        pending
        deferred
        failed
      ]
    )
  }

  scope :completed, lambda {
    where(status: "completed")
  }

  def completed?
    status == "completed"
  end
end
