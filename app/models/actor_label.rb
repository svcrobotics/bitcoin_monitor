# frozen_string_literal: true

class ActorLabel < ApplicationRecord
  belongs_to :cluster

  LABELS = %w[
    exchange_like
    whale_like
    service_like
    retail_like
    unknown
  ].freeze

  validates :label, presence: true, inclusion: { in: LABELS }
  validates :source, presence: true
  validates :confidence, numericality: {
    only_integer: true,
    greater_than_or_equal_to: 0,
    less_than_or_equal_to: 100
  }
end
