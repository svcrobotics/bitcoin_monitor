# frozen_string_literal: true

class BlockBufferModel < ApplicationRecord
  self.table_name = "block_buffers"

  # -----------------------------
  # ENUM STATUS
  # -----------------------------
  STATUSES = %w[pending enqueued processing processed failed].freeze

  validates :status, inclusion: { in: STATUSES }

  # -----------------------------
  # VALIDATIONS
  # -----------------------------
  validates :block_hash, presence: true, uniqueness: true
  validates :height, presence: true

  # -----------------------------
  # SCOPES
  # -----------------------------
  scope :pending,    -> { where(status: "pending") }
  scope :processing, -> { where(status: "processing") }
  scope :processed,  -> { where(status: "processed") }
  scope :failed,     -> { where(status: "failed") }
  scope :enqueued,   -> { where(status: "enqueued") }

  scope :ordered, -> { order(:height) }

  # -----------------------------
  # HELPERS
  # -----------------------------
  def pending?
    status == "pending"
  end

  def processing?
    status == "processing"
  end

  def processed?
    status == "processed"
  end

  def failed?
    status == "failed"
  end

  def enqueued?
    status == "enqueued"
  end
end