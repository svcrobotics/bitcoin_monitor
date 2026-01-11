# app/models/exchange_address.rb
class ExchangeAddress < ApplicationRecord
  validates :address, presence: true, uniqueness: true
end
