class Brc20TokenDailyStat < ApplicationRecord
  belongs_to :brc20_token

  scope :for_range, ->(from, to) { where(day: from..to).order(:day) }
end
