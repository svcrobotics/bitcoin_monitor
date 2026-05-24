# frozen_string_literal: true

class ExchangeCoreFlowDay < ApplicationRecord
  validates :day, presence: true, uniqueness: true
end
