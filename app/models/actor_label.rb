# frozen_string_literal: true

class ActorLabel < ApplicationRecord
  belongs_to :cluster
  belongs_to :actor_profile, optional: true

  LABELS = %w[
    exchange_like
    exchange_infrastructure_candidate
    whale_like
    whale_candidate
    service_like
    retail_like
    etf_like
    etf_candidate
    high_retention_behavior
    high_spend_through_behavior
  ].freeze

  validates :label, presence: true, inclusion: { in: LABELS }
  validates :source, presence: true
  validates :confidence, numericality: {
    only_integer: true,
    greater_than_or_equal_to: 0,
    less_than_or_equal_to: 100
  }
end
