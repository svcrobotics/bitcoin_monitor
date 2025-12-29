class Brc20Event < ApplicationRecord
  belongs_to :brc20_token, optional: true

  enum :op, { deploy: "deploy", mint: "mint", transfer: "transfer" }

  scope :valid_only,   -> { where(is_valid: true) }
  scope :for_tick,     ->(tick) { where(tick: tick.downcase) }
  scope :recent_first, -> { order(block_height: :desc, id: :desc) }
end
