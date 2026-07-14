# frozen_string_literal: true

class Layer1TxOutputSync < ApplicationRecord
  STATUSES = %w[pending processing synced failed].freeze

  validates :height, presence: true, uniqueness: true
  validates :block_hash, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :pending_first, -> { where(status: %w[pending failed]).order(:height) }
  scope :synced, -> { where(status: "synced") }
  scope :eligible_for_spent_sync, lambda { |retry_before:, stale_before:, max_attempts:|
    where(
      <<~SQL.squish,
        status = :pending
        OR (
          status = :failed
          AND attempts < :max_attempts
          AND (
            last_attempt_at IS NULL
            OR last_attempt_at < :retry_before
          )
        )
        OR (
          status = :processing
          AND COALESCE(last_attempt_at, started_at, updated_at) < :stale_before
        )
      SQL
      pending: "pending",
      failed: "failed",
      processing: "processing",
      retry_before: retry_before,
      stale_before: stale_before,
      max_attempts: max_attempts
    )
  }
end
