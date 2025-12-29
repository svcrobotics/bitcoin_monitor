# app/models/rune_token.rb
class RuneToken < ApplicationRecord
  has_many :rune_events,   dependent: :destroy
  has_many :rune_balances, dependent: :destroy
  has_many :rune_token_daily_stats, dependent: :destroy

  validates :rune_name,       presence: true
  validates :normalized_name, presence: true
  validates :rune_id_block,   presence: true
  validates :rune_id_tx,      presence: true
end
