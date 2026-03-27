class OpsecAssessment < ApplicationRecord
  has_many :opsec_answers, dependent: :destroy

  validates :score, presence: true
  validates :risk_level, inclusion: { in: %w[green yellow red] }
end
