# frozen_string_literal: true

class ActorBehaviorBuildHandoff < ApplicationRecord
  STATUSES = %w[pending processing completed failed].freeze
  TRANSITIONS = {
    "pending" => %w[processing],
    "processing" => %w[completed failed],
    "failed" => %w[processing],
    "completed" => []
  }.freeze
  IDENTITY = %w[
    cluster_id cluster_composition_version profile_version source_height source_hash
  ].freeze

  belongs_to :cluster
  belongs_to :actor_profile

  validates :cluster_composition_version,
    numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :profile_version, :source_hash, presence: true
  validates :source_height,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :status, inclusion: { in: STATUSES }
  validates :attempts,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :cluster_id,
    uniqueness: {
      scope: %i[cluster_composition_version profile_version source_height source_hash]
    }
  validate :identity_is_immutable, on: :update
  validate :transition_is_valid, on: :update
  validate :timestamps_match_state

  scope :claimable, -> { where(status: %w[pending failed]) }

  def claim!(at: Time.current)
    update!(status: "processing", attempts: attempts + 1,
      claimed_at: at, completed_at: nil, last_error_class: nil)
  end

  def complete!(at: Time.current)
    update!(status: "completed", completed_at: at, last_error_class: nil)
  end

  def fail!(error_class:)
    update!(status: "failed", completed_at: nil,
      last_error_class: error_class.to_s)
  end

  private

  def identity_is_immutable
    errors.add(:base, "handoff identity is immutable") if
      IDENTITY.any? { |attribute| will_save_change_to_attribute?(attribute) }
  end

  def transition_is_valid
    return unless will_save_change_to_status?

    previous, current = status_change_to_be_saved
    errors.add(:status, "cannot transition from #{previous} to #{current}") unless
      TRANSITIONS.fetch(previous, []).include?(current)
  end

  def timestamps_match_state
    errors.add(:claimed_at, :blank) if status == "processing" && claimed_at.blank?
    if status == "completed"
      errors.add(:completed_at, :blank) if completed_at.blank?
    elsif completed_at.present?
      errors.add(:completed_at, :invalid)
    end
  end
end
