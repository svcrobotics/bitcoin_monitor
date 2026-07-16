# frozen_string_literal: true

class ActorLabelEvaluation < ApplicationRecord
  belongs_to :cluster
  belongs_to :actor_behavior_snapshot
  validates :profile_version, :source_hash, :behavior_version, :rule_version,
    :status, :certification_scope, :certified_at, presence: true
  validates :cluster_composition_version,
    numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :source_height,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :status, inclusion: { in: %w[certified] }
  validates :certification_scope, inclusion: { in: %w[strict] }
  validate { errors.add(:rule_results, :invalid) unless rule_results.is_a?(Hash) }
end
