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
    block_coverage
      .where(
        status: %w[
          pending
          deferred
          failed
        ]
      )
  }

  scope :completed, lambda {
    block_coverage.where(status: "completed")
  }

  scope :block_coverage, lambda {
    where(
      "height > 0"
    )
  }

  scope :address_coverage, lambda {
    where(
      height: 0,
      block_hash: "addresses"
    ).where(
      "metadata ->> 'source' = ?",
      "addresses"
    ).where(
      "metadata ->> 'profile_version' = ?",
      "address_coverage_v1"
    )
  }

  def completed?
    status == "completed"
  end
end
