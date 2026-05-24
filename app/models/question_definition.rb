# frozen_string_literal: true

class QuestionDefinition < ApplicationRecord
  TIERS = %w[free advanced pro].freeze

  validates :key, presence: true, uniqueness: true
  validates :module_name, :tier, :question, :intent, :answer_service, presence: true
  validates :tier, inclusion: { in: TIERS }

  scope :active, -> { where(active: true) }
  scope :for_module, ->(name) { where(module_name: name) }
  scope :for_tier, ->(tier) { where(tier: tier) }
  scope :ordered, -> { order(:position, :id) }
end