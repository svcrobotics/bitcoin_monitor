# frozen_string_literal: true

class ClusterActorProfileHandoff < ApplicationRecord
  STATUSES = %w[pending processing completed failed].freeze
  IDENTITY_ATTRIBUTES = %w[
    cluster_height
    block_hash
    cluster_id
    composition_version
  ].freeze
  TRANSITIONS = {
    "pending" => %w[processing],
    "processing" => %w[completed failed],
    "failed" => %w[processing],
    "completed" => []
  }.freeze

  belongs_to :cluster

  validates :cluster_height,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :block_hash, presence: true
  validates :composition_version,
    numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :status, inclusion: { in: STATUSES }
  validates :attempts,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :cluster_id,
    uniqueness: {
      scope: [ :cluster_height, :block_hash, :composition_version ]
    }
  validate :identity_is_immutable, on: :update
  validate :status_transition_is_valid, on: :update
  validate :state_timestamps_are_consistent

  scope :claimable, -> { where(status: %w[pending failed]) }

  def claim!(at: Time.current)
    update!(
      status: "processing",
      attempts: attempts + 1,
      claimed_at: at,
      completed_at: nil,
      last_error_class: nil
    )
  end

  def complete!(at: Time.current)
    update!(status: "completed", completed_at: at, last_error_class: nil)
  end

  def fail!(error_class:)
    update!(status: "failed", completed_at: nil, last_error_class: error_class.to_s)
  end

  private

  def identity_is_immutable
    changed = IDENTITY_ATTRIBUTES.select { |attribute| will_save_change_to_attribute?(attribute) }
    errors.add(:base, "certification identity is immutable") if changed.any?
  end

  def status_transition_is_valid
    return unless will_save_change_to_status?

    previous, current = status_change_to_be_saved
    return if TRANSITIONS.fetch(previous, []).include?(current)

    errors.add(:status, "cannot transition from #{previous} to #{current}")
  end

  def state_timestamps_are_consistent
    errors.add(:claimed_at, :blank) if status == "processing" && claimed_at.blank?
    if status == "completed"
      errors.add(:completed_at, :blank) if completed_at.blank?
    elsif completed_at.present?
      errors.add(:completed_at, :invalid)
    end
  end
end
