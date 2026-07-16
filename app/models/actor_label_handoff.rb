# frozen_string_literal: true

class ActorLabelHandoff < ApplicationRecord
  STATUSES = %w[pending processing completed failed].freeze
  IDENTITY = %w[cluster_id cluster_composition_version profile_version source_height
    source_hash behavior_version actor_behavior_snapshot_id rule_version].freeze

  belongs_to :cluster
  belongs_to :actor_behavior_snapshot
  validates :profile_version, :source_hash, :behavior_version, :rule_version, presence: true
  validates :cluster_composition_version,
    numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :source_height, :attempts,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :status, inclusion: { in: STATUSES }
  validates :cluster_id, uniqueness: { scope: IDENTITY.drop(1).map(&:to_sym) }
  validate :identity_immutable, on: :update

  scope :claimable, -> { where(status: %w[pending failed]) }

  def claim!(at: Time.current)
    update!(status: "processing", attempts: attempts + 1, claimed_at: at,
      completed_at: nil, last_error_class: nil)
  end

  def complete!(at: Time.current)
    update!(status: "completed", completed_at: at, last_error_class: nil)
  end

  def fail!(error_class:)
    update!(status: "failed", completed_at: nil, last_error_class: error_class.to_s)
  end

  private

  def identity_immutable
    errors.add(:base, "handoff identity is immutable") if
      IDENTITY.any? { |attribute| will_save_change_to_attribute?(attribute) }
  end
end
