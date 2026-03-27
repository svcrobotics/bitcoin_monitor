class OpsecAnswer < ApplicationRecord
  belongs_to :opsec_assessment

  validates :question_key, presence: true
  validates :answer, inclusion: { in: %w[yes no unknown] }
end
