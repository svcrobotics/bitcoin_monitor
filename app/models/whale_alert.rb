class WhaleAlert < ApplicationRecord
  TYPES = %w[consolidation distribution batching other].freeze

  validates :txid, presence: true, uniqueness: true
  validates :alert_type, inclusion: { in: TYPES }

  scope :recent, -> { order(block_time: :desc, created_at: :desc) }
  scope :interesting, -> { where.not(alert_type: "other") }
  scope :min_btc, ->(v) { where("total_out_btc >= ?", v.to_d) if v.present? }
  scope :by_type, ->(t) { where(alert_type: t) if t.present? }

  scope :min_score, ->(v) { where("score >= ?", v.to_i) if v.present? }

  scope :sorted, ->(sort) do
    case sort.to_s
    when "score"
      order(score: :desc, block_time: :desc, created_at: :desc)
    else
      order(block_time: :desc, created_at: :desc)
    end
  end

end
