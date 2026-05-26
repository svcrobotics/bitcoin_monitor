# app/models/whale_core_flow_day.rb
class WhaleCoreFlowDay < ApplicationRecord
  validates :day, presence: true, uniqueness: true
end