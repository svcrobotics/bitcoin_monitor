# app/models/address_flow_stat.rb
class AddressFlowStat < ApplicationRecord
  validates :address, presence: true, uniqueness: true
end