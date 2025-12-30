class WhaleAlert < ApplicationRecord
  TYPES = %w[consolidation distribution batching other].freeze

  validates :txid, presence: true, uniqueness: true
  validates :alert_type, inclusion: { in: TYPES }
  validates :exchange_likelihood,
            numericality: { only_integer: true, allow_nil: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }

  scope :recent, -> { order(block_time: :desc, created_at: :desc) }
  scope :interesting, -> { where.not(alert_type: "other") }
  scope :for_aggregates, -> { unscope(:order) }

  scope :by_type, ->(t) { where(alert_type: t) if t.present? && TYPES.include?(t) }

  scope :min_btc, ->(v) do
    next if v.blank?
    s = v.to_s.tr(",", ".")
    next if s !~ /\A\d+(\.\d+)?\z/
    where("total_out_btc >= ?", s.to_d)
  end

  scope :min_score, ->(v) { where("score >= ?", v.to_i) if v.present? }
  scope :min_exchange, ->(v) { where("COALESCE(exchange_likelihood, 0) >= ?", v.to_i) if v.present? }

  scope :sorted, ->(sort) do
    case sort.to_s
    when "score"
      order(score: :desc, block_time: :desc, created_at: :desc)
    else
      order(block_time: :desc, created_at: :desc)
    end
  end
end
