# frozen_string_literal: true

class ActorBehaviorSnapshot < ApplicationRecord
  STATUSES = %w[
    certified
    deferred
    failed
  ].freeze

  belongs_to :cluster
  belongs_to :actor_profile

  validates :cluster_id, presence: true
  validates :actor_profile_id, presence: true
  validates :profile_version, presence: true
  validates :profile_height, presence: true
  validates :cluster_composition_version, presence: true
  validates :profile_fingerprint, presence: true
  validates :behavior_version, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :computed_at, presence: true
  validates :cluster_id, uniqueness: true
  validate :strict_certification_is_complete

  private

  def strict_certification_is_complete
    return unless status == "certified"

    errors.add(:source_hash, :blank) if source_hash.blank?
    errors.add(:certification_scope, :invalid) unless
      certification_scope == "strict"
    errors.add(:certified_at, :blank) if certified_at.blank?
  end
end
