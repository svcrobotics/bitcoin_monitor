# frozen_string_literal: true

class ExchangeCoreAddress < ApplicationRecord
  validates :address, presence: true, uniqueness: true
  validates :cluster_id, presence: true
  validates :source, presence: true
end
