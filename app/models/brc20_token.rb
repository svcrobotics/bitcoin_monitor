class Brc20Token < ApplicationRecord
  has_many :events, class_name: "Brc20Event", dependent: :destroy
  has_many :balances, class_name: "Brc20Balance", dependent: :destroy
  has_many :daily_stats, class_name: "Brc20TokenDailyStat", dependent: :destroy

  validates :tick, presence: true, uniqueness: true

  scope :most_active, -> { order(events_count: :desc) }
  scope :most_holders, -> { order(holders_count: :desc) }

  def circulating_supply
    total_minted # plus tard tu peux soustraire les burned si tu gères ça
  end
end
